# frozen_string_literal: true

require "date"
require "psych"

module Riggs
  # Splits a SKILL.md into its YAML frontmatter and its markdown body.
  #
  # Pure by design: it takes a String and touches no files, so the registry
  # keeps sole ownership of file IO and this stays trivially testable.
  #
  # Returns string-keyed data. The registry symbolizes, exactly as it does for
  # SKILL.yml, so both containers converge on one shape.
  module SkillFrontmatter
    DELIMITER = /\A---[ \t]*\z/
    BOM = "﻿"

    # Psych recurses once per level of nesting while composing a document.
    # Sufficiently deep nesting overflows the Ruby call stack and raises
    # SystemStackError -- which, unlike every other Psych failure, descends
    # from Exception rather than StandardError, so it would escape
    # SkillRegistry#read_skill_dir's rescue outright and take every skill in
    # the registry down with it. #load_mapping rejects that input before
    # Psych ever sees it, so the failure here stays an ordinary,
    # catch-and-skip ArgumentError. 100 is far beyond anything a real skill
    # file's tool schemas or description structure would need -- the bundled
    # triage_v1 skill nests 4 levels deep.
    MAX_NESTING_DEPTH = 100

    def self.parse(text)
      source = normalize(text)
      lines = source.lines
      return { data: {}, body: source } unless delimiter?(lines.first)

      close = (1...lines.length).find { |i| delimiter?(lines[i]) }
      # An opening delimiter with no closing one: treat the whole document as
      # body rather than as a broken header.
      return { data: {}, body: source } if close.nil?

      { data: load_mapping(lines[1...close].join, source: "SKILL.md frontmatter"),
        body: Array(lines[(close + 1)..]).join }
    end

    # A BOM would make the first line "﻿---" and defeat delimiter
    # detection; CRLF would leave "\r" on every chomp-less comparison. Both
    # arrive routinely from other people's repositories.
    def self.normalize(text)
      text.to_s.delete_prefix(BOM).gsub("\r\n", "\n")
    end

    def self.delimiter?(line)
      !line.nil? && DELIMITER.match?(line.chomp)
    end

    # The one place both containers load a YAML mapping -- SKILL.md
    # frontmatter and SKILL.yml alike. `source` names the caller in error
    # messages only ("SKILL.md frontmatter" / "SKILL.yml"); keeping the
    # safe_load options, the mapping check, and the depth guard here means
    # the two containers cannot drift the way they already have three times
    # on this branch.
    def self.load_mapping(yaml, source:)
      guard_nesting_depth!(yaml, source: source)

      raw = Psych.safe_load(yaml, permitted_classes: [Symbol, Date, Time], aliases: false)
      return {} if raw.nil?
      raise ArgumentError, "#{source} must be a mapping, got #{raw.class}" unless raw.is_a?(Hash)

      raw
    end

    # A text scan, not a YAML tokenizer: it knows nothing about quoted
    # strings, comments, or literal block scalars, so a description that
    # legitimately contains 100+ literal brackets, or a pasted code sample
    # indented past the limit, would be a false positive. That is an
    # accepted tradeoff against writing a real YAML parser purely to guard
    # against a stack overflow.
    def self.guard_nesting_depth!(yaml, source:)
      depth = [flow_depth(yaml), block_depth(yaml)].max
      return if depth <= MAX_NESTING_DEPTH

      raise ArgumentError, "#{source} nesting exceeds #{MAX_NESTING_DEPTH} levels"
    end

    # Flow style ([...], {...}): depth is exact -- every open is a real
    # nesting level and every close ends one -- so a running counter
    # tracking its own maximum mirrors exactly what Psych's own recursion
    # has to do to compose the document.
    def self.flow_depth(yaml)
      depth = 0
      max = 0
      yaml.each_char do |char|
        case char
        when "[", "{"
          depth += 1
          max = depth if depth > max
        when "]", "}"
          depth -= 1
        end
      end
      max
    end

    # Block style has no closing token -- nesting ends by dedenting, not by
    # a character -- so exact depth would need real indentation tracking.
    # Two cheap per-line proxies stand in instead: leading whitespace (every
    # level of block-mapping or one-item-per-line sequence nesting costs at
    # least one more column of indent, so the column count is always >= the
    # true depth) and a chain of "- " sequence markers on one line (YAML's
    # compact-nested-sequence form, which indentation alone would miss
    # entirely since it never indents). Both were confirmed empirically to
    # independently overflow Psych's stack around ~1,500 levels; 100 sits
    # far below either.
    def self.block_depth(yaml)
      yaml.each_line.map { |line| [indent_run(line), dash_chain(line)].max }.max || 0
    end

    def self.indent_run(line)
      line[/\A[ \t]*/].length
    end

    # Only a "-" immediately followed by whitespace (or end of line) counts
    # as a sequence marker, so a run of bare dashes -- a "---" document
    # marker, or a markdown "----" divider pasted into a description -- is
    # not mistaken for nesting.
    def self.dash_chain(line)
      line[/\A(?:[ \t]*-(?=[ \t]|\z))*/].to_s.count("-")
    end

    private_class_method :normalize, :delimiter?, :guard_nesting_depth!, :flow_depth, :block_depth,
                         :indent_run, :dash_chain
  end
end

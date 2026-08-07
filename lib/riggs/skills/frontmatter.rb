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

    def self.parse(text)
      source = normalize(text)
      lines = source.lines
      return { data: {}, body: source } unless delimiter?(lines.first)

      close = (1...lines.length).find { |i| delimiter?(lines[i]) }
      # An opening delimiter with no closing one: treat the whole document as
      # body rather than as a broken header.
      return { data: {}, body: source } if close.nil?

      { data: load_yaml(lines[1...close].join),
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

    def self.load_yaml(yaml)
      raw = Psych.safe_load(yaml, permitted_classes: [Symbol, Date, Time], aliases: false)
      return {} if raw.nil?
      raise ArgumentError, "SKILL.md frontmatter must be a mapping, got #{raw.class}" unless raw.is_a?(Hash)

      raw
    end

    private_class_method :normalize, :delimiter?, :load_yaml
  end
end

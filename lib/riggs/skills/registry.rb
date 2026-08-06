# frozen_string_literal: true

require "psych"
require_relative "frontmatter"

module Riggs
  class SkillRegistry
    def initialize(roots: nil)
      @roots = Array(roots || default_roots)
    end

    # load("triage_v1") or load("triage_v1@1.0.0")
    def load(spec)
      name, pinned = parse_spec(spec)
      candidates = find_candidates(name)
      return nil if candidates.empty?

      if pinned
        match = candidates.find { |c| version_eq?(c[:version], pinned) }
        return match ? format_skill(match) : nil
      end

      best = candidates.max_by { |c| Gem::Version.new(normalize_version(c[:version])) }
      format_skill(best)
    rescue ArgumentError
      # Non-semver versions: fall back to first candidate
      format_skill(candidates.first)
    end

    def list
      by_name = Hash.new { |h, k| h[k] = [] }
      each_skill_dir do |dir, entry|
        data = read_skill_dir(dir, entry)
        next unless data

        by_name[data[:name]] << { version: data[:version], description: data[:description] }
      end
      by_name.keys.sort.map { |name| summarize(name, by_name[name]) }
    end

    def list_names
      list.map { |s| s[:name] }
    end

    private

    def parse_spec(spec)
      s = spec.to_s
      if s.include?("@")
        name, ver = s.split("@", 2)
        [name, ver]
      else
        [s, nil]
      end
    end

    def find_candidates(name)
      found = []
      each_skill_dir do |dir, entry|
        # Match directory name exactly, or name@version folder, or YAML name field
        data = read_skill_dir(dir, entry)
        next unless data
        next unless data[:name] == name || entry == name || entry.start_with?("#{name}@")

        found << data
      end
      found
    end

    def each_skill_dir
      @roots.each do |root|
        next unless Dir.exist?(root)

        Dir.children(root).each do |entry|
          dir = File.join(root, entry)
          next unless File.directory?(dir)

          yield dir, entry
        end
      end
    end

    def read_skill_dir(dir, entry)
      source = skill_source(dir)
      return nil unless source

      data = Identity.deep_symbolize(source[:data])
      version = (data[:version] || version_from_dirname(entry) || "0.1.0").to_s
      name = (data[:name] || entry.split("@").first).to_s

      {
        name: name,
        version: version,
        description: (data[:description] || "").to_s,
        system_prompt: resolve_prompt(dir, data, source[:body]),
        tools: normalize_tools(Array(data[:tools])),
        mcp_servers: Array(data[:mcp_servers]).map(&:to_s),
        path: dir
      }
    end

    # SKILL.yml wins when both exist. Adding SKILL.md support must not change
    # how a skill that already ships behaves, so the native container takes
    # precedence and nothing is announced about the one that lost.
    def skill_source(dir)
      yml = File.join(dir, "SKILL.yml")
      if File.exist?(yml)
        raw = Psych.safe_load(File.read(yml), permitted_classes: [Symbol], aliases: true) || {}
        return { data: raw, body: nil }
      end

      md = File.join(dir, "SKILL.md")
      return nil unless File.exist?(md)

      SkillFrontmatter.parse(File.read(md))
    end

    # Explicit key beats a file -- the rule SKILL.yml already followed with
    # prompt.md. The markdown body slots in between: it is the natural home for
    # a SKILL.md's instructions, but an author who writes system_prompt: in
    # frontmatter has said something more specific.
    def resolve_prompt(dir, data, body)
      explicit = data[:system_prompt]
      return explicit.to_s unless explicit.nil? || explicit.to_s.empty?
      return body.to_s unless body.nil? || body.to_s.strip.empty?

      prompt_file = File.join(dir, "prompt.md")
      File.exist?(prompt_file) ? File.read(prompt_file) : ""
    end

    def normalize_tools(tools)
      tools.map do |t|
        h = t.is_a?(Hash) ? Identity.deep_symbolize(t) : { name: t.to_s }
        {
          name: h[:name].to_s,
          description: (h[:description] || "").to_s,
          input_schema: h[:input_schema] || h[:parameters] || { type: "object", properties: {} },
          mcp_server: h[:mcp_server]&.to_s
        }
      end
    end

    def format_skill(data)
      {
        name: data[:name],
        version: data[:version],
        description: data[:description],
        system_prompt: data[:system_prompt],
        tools: data[:tools],
        mcp_servers: data[:mcp_servers]
      }
    end

    def version_from_dirname(entry)
      return unless entry.include?("@")

      entry.split("@", 2).last
    end

    def normalize_version(ver)
      ver.to_s.sub(/\Av/i, "")
    end

    # The description reported for a name must belong to the same version
    # reported as `latest`, or the table describes one skill and versions
    # another.
    def summarize(name, entries)
      ordered = entries.uniq { |e| e[:version] }.sort_by { |e| sortable_version(e[:version]) }
      newest = ordered.last
      { name: name, versions: ordered.map { |e| e[:version] },
        latest: newest&.fetch(:version), description: newest ? newest[:description] : "" }
    end

    def sortable_version(ver)
      Gem::Version.new(normalize_version(ver))
    rescue StandardError
      Gem::Version.new("0")
    end

    def version_eq?(a, b)
      Gem::Version.new(normalize_version(a)) == Gem::Version.new(normalize_version(b))
    rescue ArgumentError
      a.to_s == b.to_s
    end

    def default_roots
      [
        File.expand_path("./config/riggs/skills"),
        File.expand_path("../../config/riggs/skills", __dir__)
      ]
    end
  end
end

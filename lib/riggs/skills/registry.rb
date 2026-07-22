# frozen_string_literal: true

require "psych"
require "pathname"

module Riggs
  class SkillRegistry
    def initialize(roots: nil)
      @roots = Array(roots || default_roots)
    end

    def load(name)
      name = name.to_s
      @roots.each do |root|
        dir = File.join(root, name)
        skill_yml = File.join(dir, "SKILL.yml")
        next unless File.exist?(skill_yml)

        raw = Psych.safe_load(File.read(skill_yml), permitted_classes: [Symbol], aliases: true) || {}
        data = Identity.deep_symbolize(raw)
        prompt_file = File.join(dir, "prompt.md")
        system_prompt = data[:system_prompt]
        system_prompt = File.read(prompt_file) if (system_prompt.nil? || system_prompt.empty?) && File.exist?(prompt_file)

        return {
          name: (data[:name] || name).to_s,
          version: (data[:version] || "0.1.0").to_s,
          system_prompt: system_prompt.to_s,
          tools: Array(data[:tools])
        }
      end
      nil
    end

    def list
      found = []
      @roots.each do |root|
        next unless Dir.exist?(root)

        Dir.children(root).each do |entry|
          path = File.join(root, entry, "SKILL.yml")
          found << entry if File.exist?(path)
        end
      end
      found.uniq.sort
    end

    private

    def default_roots
      [
        File.expand_path("./config/riggs/skills"),
        File.expand_path("../../config/riggs/skills", __dir__)
      ]
    end
  end
end

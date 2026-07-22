# frozen_string_literal: true

require "test_helper"
require "fileutils"

class TestSkills < Minitest::Test
  def test_load_latest_and_pin
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/triage_v1_old")
      File.write("config/riggs/skills/triage_v1_old/SKILL.yml", <<~YAML)
        name: triage_v1
        version: "0.9.0"
        system_prompt: old
        tools: []
      YAML

      reg = Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
      latest = reg.load("triage_v1")
      assert_equal "1.0.0", latest[:version]
      assert latest[:tools].any? { |t| t[:name] == "lookup_runbook" }

      pinned = reg.load("triage_v1@0.9.0")
      assert_equal "0.9.0", pinned[:version]
      assert_equal "old", pinned[:system_prompt]

      assert_nil reg.load("triage_v1@9.9.9")
    end
  end

  def test_list_includes_versions
    with_tmp_project do
      reg = Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
      names = reg.list.map { |s| s[:name] }
      assert_includes names, "triage_v1"
    end
  end
end

# frozen_string_literal: true

require "test_helper"

class TestSkillsAndTriggers < Minitest::Test
  def test_skill_registry
    with_tmp_project do
      reg = Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
      skill = reg.load("triage_v1")
      refute_nil skill
      assert_match(/triage/i, skill[:system_prompt])
      assert_includes reg.list_names, "triage_v1"
      assert skill[:tools].any?
    end
  end

  def test_keyword_trigger
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      assert Riggs::Triggers.match(workflow, text: "please triage this")
      refute Riggs::Triggers.match(
        { triggers: [{ type: "keyword", keywords: ["invoice"] }] },
        text: "hello"
      )
    end
  end
end

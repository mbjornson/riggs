# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestToolLoop < Minitest::Test
  def test_mock_tool_call_then_final
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      # Force classify step to request a lookup so Mock emits tool_calls
      workflow[:steps].first.input.replace(
        "Please lookup runbook for this ticket: {{workflow.input.ticket}}"
      )

      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      io = StringIO.new
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
        gate_handler: ->(*) { :approved }
      )

      engine.execute(io, input: { ticket: "Password reset request" })
      assert_equal :completed, engine.status
      assert engine.llm_calls >= 2, "expected tool loop to make >= 2 LLM calls, got #{engine.llm_calls}"
      events = engine.audit_log.map { |e| e[:event_type] }
      assert_includes events, "tool_call"
      assert_includes events, "tool_result"
      assert_match(/classification=OK|used_tool|lookup/i, engine.outputs[:classification].to_s)
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "stringio"
require "json"

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

  def test_tool_calling_step_persists_tool_calls_and_matching_tool_result
    with_tmp_project do
      engine = tool_calling_engine
      engine.execute(StringIO.new, input: { ticket: "Password reset request" })
      assert_equal :completed, engine.status

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      rows = storage.list_messages(engine.session_id, step_key: "classify")

      assert_equal %w[user assistant tool assistant], rows.map { |r| r["role"] }
      assert_nil rows[0]["tool_calls"], "the user turn carries no tool_calls"

      requesting = rows[1]
      refute_nil requesting["tool_calls"], "the assistant turn requesting tools must store them"
      assert_equal "mock", requesting["provider"]
      calls = JSON.parse(requesting["tool_calls"])
      assert_equal 1, calls.size
      assert_equal "lookup_runbook", calls.first["name"]

      tool_row = rows[2]
      assert_equal calls.first["id"], tool_row["tool_call_id"], "tool result must reference its call id"
      assert_equal "lookup_runbook", tool_row["tool_name"]
      assert_match(/Runbook/, tool_row["content"])
      assert_nil tool_row["provider"], "tool results are not produced by a provider"
      storage.close
    end
  end

  def test_persist_defaults_to_nil_and_disables_persistence
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })
    step = Riggs::Workflow::StepNode.from_hash("id" => "solo", "input" => "hello")

    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router,
      mcp_manager: nil,
      skill_registry: nil,
      audit: ->(**_kwargs) {},
      llm_calls: 0,
      max_llm_calls: 5,
      timeout_seconds: 30,
      started_at: Time.now,
      session_id: "no-session"
    )

    outcome = loop_runner.run(
      step: step,
      chain: ["mock"],
      messages: [{ role: "user", content: "hello" }],
      system_prompt: "test",
      io: StringIO.new
    )

    assert_equal "mock", outcome[:provider]
    refute_empty outcome[:content], "a loop without a persist callback still returns its answer"
  end

  def test_records_one_provider_call_per_turn
    recorded = []
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })
    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil,
      audit: ->(**) {}, record_call: ->(**kw) { recorded << kw },
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )

    loop_runner.run(step: build_step, chain: ["mock"], messages: [{ role: "user", content: "hello" }],
                    system_prompt: "sys", io: StringIO.new)

    assert_equal 1, recorded.length
    assert_equal "triage", recorded.first[:step_key]
    assert recorded.first[:usage][:measured]
    assert_equal 1, recorded.first[:relay_attempt]
  end

  def test_runs_without_a_record_call_callable
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })
    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil, audit: ->(**) {},
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )

    result = loop_runner.run(step: build_step, chain: ["mock"],
                             messages: [{ role: "user", content: "hello" }],
                             system_prompt: "sys", io: StringIO.new)

    refute_nil result[:content]
  end

  private

  def build_step
    Riggs::Workflow::StepNode.from_hash(
      { "id" => "triage", "agent" => "triager", "input" => "x", "output_var" => "out" }
    )
  end

  def tool_calling_engine
    workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
    # Force the classify step to request a lookup so Mock emits tool_calls
    workflow[:steps].first.input.replace("Please lookup runbook for this ticket: {{workflow.input.ticket}}")

    Riggs::Workflow::GraphEngine.new(
      workflow: workflow,
      user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
      db_path: "./db/riggs.sqlite3",
      hub_config: Riggs::Identity.load_config,
      skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
      gate_handler: ->(*) { :approved }
    )
  end
end

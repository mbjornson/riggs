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

  def test_compacts_before_calling_the_provider_when_over_budget
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 200, reserve: 0, keep_recent: 50
    )
    loop_runner = build_loop(compactor: compactor)
    messages = 20.times.map { |i| { role: "user", content: "turn#{i} #{'x' * 200}" } }

    result = loop_runner.run(step: build_step, chain: ["mock"], messages: messages,
                             system_prompt: "sys", io: StringIO.new)

    refute_nil result[:content], "the run completes rather than raising"
    assert_operator messages.length, :<, 20, "the message array was compacted in place"
  end

  def test_audits_context_compacted
    events = []
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 200, reserve: 0, keep_recent: 50
    )
    loop_runner = build_loop(compactor: compactor, audit: ->(**kw) { events << kw })

    loop_runner.run(step: build_step, chain: ["mock"],
                    messages: 20.times.map { |i| { role: "user", content: "t#{i} #{'x' * 200}" } },
                    system_prompt: "sys", io: StringIO.new)

    compaction = events.find { |e| e[:event_type] == "context_compacted" }

    refute_nil compaction
    assert_operator compaction[:payload][:after], :<, compaction[:payload][:before]
  end

  def test_no_compaction_without_a_compactor
    loop_runner = build_loop(compactor: nil)

    result = loop_runner.run(step: build_step, chain: ["mock"],
                             messages: [{ role: "user", content: "hi" }],
                             system_prompt: "sys", io: StringIO.new)

    refute_nil result[:content]
  end

  def test_step_with_its_own_relay_chain_compacts_through_that_chain_not_the_first_steps
    Dir.mktmpdir("riggs-chain-test") do |dir|
      db_path = File.join(dir, "db", "riggs.sqlite3")
      storage = Riggs::Storage.new(db_path: db_path)

      workflow = {
        name: "chain_test",
        context_window: 12,
        reserve_tokens: 0,
        keep_recent_tokens: 1,
        max_llm_calls: 20,
        timeout_seconds: 60,
        providers: {
          default: { relay_chain: ["mock"] },
          special: { relay_chain: ["special_mock"] },
          special_mock: { type: "mock" }
        },
        steps: [
          Riggs::Workflow::StepNode.from_hash(id: "first", input: "hello", output_var: "first", next: "second"),
          Riggs::Workflow::StepNode.from_hash(id: "second", provider: "special",
                                              input: "please lookup runbook now", output_var: "second")
        ]
      }

      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: { id: "test_user", memory_namespace: "test" },
        storage: storage,
        db_path: db_path,
        mcp_manager: lookup_tool_mcp_manager
      )

      engine.execute(StringIO.new, input: {})
      assert_equal :completed, engine.status

      compaction = engine.audit_log.find do |e|
        e[:event_type] == "context_compacted" && e[:payload][:step] == "second"
      end
      refute_nil compaction, "compaction must actually trigger for step 'second' -- " \
                             "otherwise this test proves nothing about which chain it used"

      providers = storage.db.execute(
        "SELECT provider FROM riggs_provider_calls WHERE session_id = ? AND step_key = ?",
        [engine.session_id, "second"]
      ).map { |row| row["provider"] }

      refute_includes providers, "mock",
                      "step 'second' declares its own relay_chain (special_mock); its compaction " \
                      "must not summarize through the first step's chain (mock)"
      assert_includes providers, "special_mock"
    ensure
      storage&.close
    end
  end

  private

  def build_step
    Riggs::Workflow::StepNode.from_hash(
      { "id" => "triage", "agent" => "triager", "input" => "x", "output_var" => "out" }
    )
  end

  def build_loop(compactor: nil, audit: ->(**) {})
    Riggs::Workflow::ToolLoop.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      mcp_manager: nil, skill_registry: nil, audit: audit, compactor: compactor,
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )
  end

  # A minimal MCP manager double whose only tool is the "lookup_runbook"
  # built-in ToolLoop stub -- enough to make Mock emit a tool call so a
  # step's transcript grows across multiple turns without needing a real
  # skill/registry fixture.
  def lookup_tool_mcp_manager
    Class.new do
      def list_tools
        [{ name: "lookup_runbook", description: "Look up a runbook", input_schema: {}, server: "local" }]
      end

      def call_tool(*, **)
        "unused -- lookup_runbook is handled by ToolLoop's built-in stub"
      end

      def close; end
    end.new
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

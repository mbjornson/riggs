# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestGraphEngine < Minitest::Test
  # Records the order of the two writes that end a run, so we can prove the
  # final audit row is visible before the session looks terminal to a poller.
  class OrderRecordingStorage < Riggs::Storage
    def calls
      @calls ||= []
    end

    def audit(session_id:, event_type:, payload: {})
      calls << "audit:#{event_type}"
      super
    end

    def update_session(session_id, status:, ended: false)
      calls << "status:#{status}"
      super
    end
  end

  def test_an_unrecognised_gate_result_is_treated_as_approved
    with_tmp_project do
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml"),
        user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        gate_handler: ->(*) { :deferred },
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
      )
      engine.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })

      assert_equal :completed, engine.status
      assert engine.outputs[:debug_plan], "the gated step must run"
      assert engine.outputs[:final_summary],
             "an unknown gate result must follow the 'if gate.approved' branch, not dead-end the run"
    end
  end

  def test_final_audit_row_is_written_before_the_session_looks_terminal
    with_tmp_project do
      storage = OrderRecordingStorage.new(db_path: "./db/riggs.sqlite3")
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml"),
        user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
        storage: storage,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        gate_handler: ->(*) { :approved },
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
      )
      engine.execute(StringIO.new, input: { ticket: "Login ERROR timeout" })

      audit_at = storage.calls.index("audit:workflow_complete")
      status_at = storage.calls.index("status:completed")

      refute_nil audit_at, "the run must audit workflow_complete"
      refute_nil status_at, "the run must mark the session completed"
      assert audit_at < status_at,
             "workflow_complete must be audited before the session reads as terminal, " \
             "otherwise a poller can see done=true and stop before the final event exists"
    end
  end

  def test_three_steps_with_hitl_auto_approve
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      io = StringIO.new
      approvals = []

      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
        gate_handler: lambda { |step, out|
          approvals << step.id
          out.puts "auto-approve #{step.id}"
          :approved
        }
      )

      engine.execute(io, input: { ticket: "Production outage ERROR database down" })

      assert_equal :completed, engine.status
      assert_includes approvals, "debug"
      assert engine.outputs[:classification]
      assert engine.outputs[:debug_plan]
      assert engine.outputs[:final_summary]
      assert engine.session_id

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      session = storage.find_session(engine.session_id)
      assert_equal "completed", session["status"]
      events = storage.list_audit(engine.session_id).map { |r| r["event_type"] }
      assert_includes events, "gate_pause"
      assert_includes events, "gate_decision"
      assert_includes events, "workflow_complete"
      storage.close
    end
  end

  def test_messages_persisted_in_turn_order_for_a_two_step_run
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")

      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        gate_handler: ->(*) { :approved }
      )
      # "Password reset request" classifies OK, so the run is classify -> summarize.
      engine.execute(StringIO.new, input: { ticket: "Password reset request" })
      assert_equal :completed, engine.status

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      rows = storage.list_messages(engine.session_id)

      assert_equal %w[user assistant user assistant], rows.map { |r| r["role"] }
      assert_equal [1, 2, 3, 4], rows.map { |r| r["seq"] }, "seq must be gapless from 1"
      assert_equal %w[classify classify summarize summarize], rows.map { |r| r["step_key"] }
      assert_match(/Password reset request/, rows[0]["content"], "the resolved step input is the user turn")
      assert_equal engine.outputs[:classification], rows[1]["content"]
      assert_equal engine.outputs[:final_summary], rows[3]["content"]
      assert_equal "mock", rows[1]["provider"], "assistant turns record the provider that answered"
      assert_nil rows[0]["provider"], "user turns have no provider"
      assert_equal 2, storage.list_messages(engine.session_id, step_key: "summarize").size
      storage.close
    end
  end

  def test_gate_reject_aborts
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      io = StringIO.new

      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        gate_handler: ->(*) { :rejected }
      )
      engine.execute(io, input: { ticket: "Something ERROR happened" })
      assert_equal :rejected, engine.status
    end
  end

  def test_ok_path_skips_debug
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      io = StringIO.new
      gates = []

      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        gate_handler: lambda { |s, _|
          gates << s.id
          :approved
        }
      )
      engine.execute(io, input: { ticket: "Password reset request" })
      assert_equal :completed, engine.status
      assert_empty gates
      assert engine.outputs[:final_summary]
      refute engine.outputs[:debug_plan]
    end
  end

  def test_build_messages_keeps_all_outputs_under_budget
    engine = engine_with(context_window: 128_000)
    engine.instance_variable_set(:@outputs, { first: "a" * 100, second: "b" * 100 })

    messages = engine.send(:build_messages, "next input")

    assert_equal 3, messages.length, "two history turns plus the new user turn"
    assert_equal "user", messages.last[:role]
  end

  def test_build_messages_drops_oldest_outputs_over_budget
    engine = engine_with(context_window: 100, reserve_tokens: 0)
    engine.instance_variable_set(:@outputs, { first: "a" * 4_000, second: "b" * 4_000 })

    messages = engine.send(:build_messages, "next input")

    assert_operator messages.length, :<, 3
  end

  def test_build_messages_returns_history_oldest_first
    engine = engine_with(context_window: 128_000)
    engine.instance_variable_set(:@outputs, { first: "OLDEST", second: "NEWEST" })

    contents = engine.send(:build_messages, "input").map { |m| m[:content] }

    assert_operator contents.index("OLDEST"), :<, contents.index("NEWEST"),
                    "history must stay chronological even though selection walks backwards"
  end

  # first (older) is small enough to fit the ceiling on its own; second
  # (newer) alone already blows past it. A `break` on the first oversized
  # turn stops the newest-to-oldest walk before `first` is ever evaluated, so
  # it would be silently dropped even though there was ample room for it.
  # `next` skips only the oversized turn and keeps walking, so `first`
  # survives. test_build_messages_drops_oldest_outputs_over_budget cannot
  # distinguish the two because both of its outputs are equally oversized.
  def test_build_messages_keeps_an_older_turn_that_fits_past_a_newer_oversized_one
    engine = engine_with(context_window: 100, reserve_tokens: 0)
    engine.instance_variable_set(:@outputs, { first: "x" * 20, second: "y" * 20_000 })

    messages = engine.send(:build_messages, "next input")

    assert(messages.any? { |m| m[:content] == "x" * 20 },
           "an older turn that fits the budget must survive a newer oversized one, " \
           "not be discarded because the walk stopped early")
  end

  def test_cli_only_chain_audits_compaction_unavailable
    engine = engine_with(context_window: 32_000, chain: ["claude_cli"])

    engine.send(:announce_compaction_availability!, ["claude_cli"])
    events = engine.audit_log.map { |e| e[:event_type] }

    assert_includes events, "compaction_unavailable"
  end

  def test_measurable_chain_does_not_announce
    engine = engine_with(context_window: 32_000, chain: ["mock"])

    engine.send(:announce_compaction_availability!, ["mock"])

    refute_includes engine.audit_log.map { |e| e[:event_type] }, "compaction_unavailable"
  end

  def test_announcement_happens_only_once
    engine = engine_with(context_window: 32_000, chain: ["claude_cli"])

    3.times { engine.send(:announce_compaction_availability!, ["claude_cli"]) }

    assert_equal 1, engine.audit_log.count { |e| e[:event_type] == "compaction_unavailable" }
  end

  private

  # Builds a minimal GraphEngine directly from a workflow hash rather than
  # through Loader.load, matching the Dir.mktmpdir + File.join(dir, "db",
  # "riggs.sqlite3") + explicit storage.close idiom used in
  # test_storage_audit.rb, and the Riggs::Workflow::StepNode.from_hash idiom
  # used in test_tool_loop.rb / test_providers.rb. Two steps ("first",
  # "second") give build_messages a deterministic chronological order to
  # select and emit history from. Storage is built explicitly (rather than
  # left for GraphEngine to construct) so teardown can close it before the
  # tmpdir is removed -- WAL mode leaves -wal/-shm files that a still-open
  # connection can race with FileUtils.remove_entry.
  def engine_with(context_window:, reserve_tokens: 16_384, keep_recent_tokens: 20_000, chain: ["mock"])
    dir = Dir.mktmpdir("riggs-graph-engine")
    (@engine_with_dirs ||= []) << dir
    storage = Riggs::Storage.new(db_path: File.join(dir, "db", "riggs.sqlite3"))
    (@engine_with_storages ||= []) << storage

    workflow = {
      name: "budget_test",
      context_window: context_window,
      reserve_tokens: reserve_tokens,
      keep_recent_tokens: keep_recent_tokens,
      max_llm_calls: 20,
      providers: { default: { relay_chain: chain } },
      steps: [
        Riggs::Workflow::StepNode.from_hash(id: "first", output_var: "first"),
        Riggs::Workflow::StepNode.from_hash(id: "second", output_var: "second")
      ]
    }

    Riggs::Workflow::GraphEngine.new(
      workflow: workflow,
      user_identity: { id: "test_user", memory_namespace: "test" },
      storage: storage,
      db_path: File.join(dir, "db", "riggs.sqlite3")
    )
  end

  def teardown
    Array(@engine_with_storages).each(&:close)
    Array(@engine_with_dirs).each { |dir| FileUtils.remove_entry(dir) }
  end
end

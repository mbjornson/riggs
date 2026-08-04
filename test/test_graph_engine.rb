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
end

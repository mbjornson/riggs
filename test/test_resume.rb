# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestResume < Minitest::Test
  def test_paused_gate_saves_resume_state_and_halts_run
    with_tmp_project do
      engine = build_engine(gate_handler: ->(*) { :paused })
      engine.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })

      assert_equal :paused, engine.status
      assert engine.outputs[:classification], "steps before the gate must still run"
      refute engine.outputs[:debug_plan], "the gated step must not execute while paused"

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_equal "paused", storage.find_session(engine.session_id)["status"]

      state = storage.load_resume_state(engine.session_id)
      assert_equal "debug", state[:current_step_id]
      assert_equal engine.llm_calls, state[:llm_calls]
      assert state[:outputs][:classification], "resume state must carry prior step outputs"

      events = storage.list_audit(engine.session_id).map { |r| r["event_type"] }
      assert_includes events, "gate_pause"
      refute_includes events, "workflow_complete"
      storage.close
    end
  end

  def test_resume_completes_a_paused_session
    with_tmp_project do
      paused = build_engine(gate_handler: ->(*) { :paused })
      paused.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })
      assert_equal :paused, paused.status

      gates = []
      resumed = resume_session(paused.session_id, gate_handler: lambda { |step, _io|
        gates << step.id
        :approved
      })

      assert_equal :completed, resumed.status
      assert_equal paused.session_id, resumed.session_id, "resume must reuse the existing session row"
      assert_empty gates, "the gate that paused the run must not re-prompt on resume"
      assert_equal paused.outputs[:classification], resumed.outputs[:classification], "prior outputs must be restored"
      assert resumed.outputs[:debug_plan], "the gated step must execute on resume"
      assert resumed.outputs[:final_summary]
      assert resumed.llm_calls > paused.llm_calls, "the llm_calls counter must continue from the restored value"

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_equal "completed", storage.find_session(paused.session_id)["status"]
      assert_nil storage.load_resume_state(paused.session_id), "resume_state must be cleared once the run leaves paused"

      debug_input = storage.list_messages(paused.session_id, step_key: "debug").first["content"]
      assert_includes debug_input, paused.outputs[:classification].to_s,
                      "the resumed step must template restored outputs into its input"
      refute_includes debug_input, "<empty>"

      events = storage.list_audit(paused.session_id).map { |r| r["event_type"] }
      assert_includes events, "workflow_resume"
      assert_includes events, "workflow_complete"
      storage.close
    end
  end

  def test_messages_after_resume_continue_the_seq_series
    with_tmp_project do
      paused = build_engine(gate_handler: ->(*) { :paused })
      paused.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      before = storage.list_messages(paused.session_id)
      assert_equal [1, 2], before.map { |r| r["seq"] }
      assert_equal %w[classify classify], before.map { |r| r["step_key"] }

      resumed = resume_session(paused.session_id, gate_handler: ->(*) { :approved })
      assert_equal :completed, resumed.status

      after = storage.list_messages(paused.session_id)
      seqs = after.map { |r| r["seq"] }
      assert_equal seqs.uniq, seqs, "seq must not collide across a resume"
      assert_equal (1..after.size).to_a, seqs, "seq must stay gapless across a resume"
      assert_equal before.map { |r| r["id"] }, after.take(2).map { |r| r["id"] }, "pre-pause messages are preserved"
      assert_equal %w[debug debug summarize summarize], after.drop(2).map { |r| r["step_key"] },
                   "messages written after resume append to the same session"
      storage.close
    end
  end

  def test_resume_raises_on_a_session_that_is_not_paused
    with_tmp_project do
      engine = build_engine(gate_handler: ->(*) { :approved })
      engine.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })
      assert_equal :completed, engine.status

      error = assert_raises(Riggs::WorkflowError) { resume_session(engine.session_id) }
      assert_match(/not paused/i, error.message)

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_equal "completed", storage.find_session(engine.session_id)["status"],
                   "a refused resume must not mark the session failed"
      storage.close
    end
  end

  def test_resume_raises_on_an_unknown_session
    with_tmp_project do
      error = assert_raises(Riggs::WorkflowError) { resume_session("no-such-session") }
      assert_match(/not found/i, error.message)
    end
  end

  def test_cli_workflow_resume_completes_a_paused_session
    with_tmp_project do
      paused = build_engine(gate_handler: ->(*) { :paused })
      paused.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })

      out, = capture_io { Riggs::CLI.start(["workflow:resume", paused.session_id, "--user", "eng_bob"]) }
      assert_match(/Step: Debug Escalation/i, out, "resume prints the same step output format as workflow:run")
      assert_match(/completed/i, out)

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_equal "completed", storage.find_session(paused.session_id)["status"]
      storage.close
    end
  end

  def test_cli_workflow_resume_exits_non_zero_when_the_session_is_not_resumable
    with_tmp_project do
      engine = build_engine(gate_handler: ->(*) { :approved })
      engine.execute(StringIO.new, input: { ticket: "Password reset request" })

      _out, err = capture_io do
        assert_raises(SystemExit) { Riggs::CLI.start(["workflow:resume", engine.session_id, "--user", "eng_bob"]) }
      end
      assert_match(/not paused/i, err)
    end
  end

  def test_cli_workflow_resume_requires_run_workflow_permission
    with_tmp_project do
      paused = build_engine(gate_handler: ->(*) { :paused })
      paused.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })

      capture_io do
        assert_raises(SystemExit, "a viewer without run_workflow must not resume a run") do
          Riggs::CLI.start(["workflow:resume", paused.session_id, "--user", "view_cara"])
        end
      end

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_equal "paused", storage.find_session(paused.session_id)["status"]
      storage.close
    end
  end

  def test_a_losing_resumer_refuses_rather_than_double_executing_the_step
    with_tmp_project do
      paused = build_engine(gate_handler: ->(*) { :paused })
      paused.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })
      assert_equal :paused, paused.status

      error = assert_raises(Riggs::WorkflowError) do
        Riggs::Workflow::GraphEngine.resume(
          session_id: paused.session_id,
          user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
          workflow: Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml"),
          storage: RacingStorage.new(db_path: "./db/riggs.sqlite3"),
          db_path: "./db/riggs.sqlite3",
          hub_config: Riggs::Identity.load_config,
          skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
          io: StringIO.new
        )
      end
      assert_match(/claim|not paused|already/i, error.message)

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_empty storage.list_messages(paused.session_id, step_key: "debug"),
                   "the loser must not have executed the gated step"
      storage.close
    end
  end

  private

  # A competing resumer that claims the session in the window between the
  # status read and the write. Without an atomic claim both resumers proceed
  # and the gated step executes twice.
  class RacingStorage < Riggs::Storage
    def load_resume_state(session_id)
      state = super
      unless @raced
        @raced = true
        Riggs::Storage.new(db_path: db_path).then do |rival|
          rival.claim_paused_session(session_id)
          rival.close
        end
      end
      state
    end
  end

  def resume_session(session_id, gate_handler: nil, io: StringIO.new)
    Riggs::Workflow::GraphEngine.resume(
      session_id: session_id,
      user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
      workflow: Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml"),
      db_path: "./db/riggs.sqlite3",
      hub_config: Riggs::Identity.load_config,
      skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
      gate_handler: gate_handler,
      io: io
    )
  end

  def build_engine(gate_handler:)
    Riggs::Workflow::GraphEngine.new(
      workflow: Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml"),
      user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
      db_path: "./db/riggs.sqlite3",
      hub_config: Riggs::Identity.load_config,
      skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
      gate_handler: gate_handler
    )
  end
end

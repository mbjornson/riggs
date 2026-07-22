# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestGraphEngine < Minitest::Test
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

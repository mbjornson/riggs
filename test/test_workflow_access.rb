# frozen_string_literal: true

require "test_helper"
require "rack/mock"
require "stringio"

class TestWorkflowAccess < Minitest::Test
  def setup
    @insecure_identity = Riggs::Web::App.insecure_identity
    Riggs::Web::App.insecure_identity = true
  end

  def teardown
    Riggs::Web::App.insecure_identity = @insecure_identity
  end

  def test_run_workflow_still_runs_anything
    assert_permits(identity(:engineer, %w[run_workflow]), owner: nil, tier: :bundled)
    assert_permits(identity(:engineer, %w[run_workflow]), owner: "pm", tier: :project)
  end

  def test_an_owner_may_run_the_workflow_it_owns
    assert_permits(identity(:pm, %w[run_owned_workflow]), owner: "pm", tier: :bundled)
    assert_permits(identity(:pm, %w[run_owned_workflow]), owner: "pm", tier: :global)
  end

  def test_an_owner_may_not_run_another_roles_workflow
    denial = denial_for(identity(:pm, %w[run_owned_workflow]), owner: "engineer", tier: :global)

    assert_match(/owned by 'engineer'/, denial)
    assert_match(/\bpm\b/, denial)
  end

  # An unlabelled workflow is not "owned by everyone". Defaulting the other way
  # would hand every existing workflow in every repo to the first role granted
  # run_owned_workflow.
  def test_a_workflow_with_no_owner_needs_the_unscoped_permission
    denial = denial_for(identity(:pm, %w[run_owned_workflow]), owner: nil, tier: :bundled)

    assert_match(/declares no owner_role/, denial)
  end

  # Trust is granted once, and a repository stays mutable afterwards. Honouring
  # a project-tier owner_role would let a repo trusted while benign later label
  # a workflow `owner_role: pm` and have the least technical operator run it --
  # the same reason a project may not set its own base_url.
  def test_a_repository_cannot_label_its_own_workflow_into_a_role
    denial = denial_for(identity(:pm, %w[run_owned_workflow]), owner: "pm", tier: :project)

    assert_match(/repository/i, denial)
    assert_match(/run_workflow/, denial)
  end

  def test_a_role_with_neither_permission_is_told_which_one_it_lacks
    denial = denial_for(identity(:viewer, %w[read_workflow]), owner: "pm", tier: :bundled)

    assert_match(/run_workflow/, denial)
    assert_match(/run_owned_workflow/, denial)
  end

  # The rule above is only worth anything if the commands that execute
  # actually ask it. All four entry points -- these two plus the web pair --
  # gated on the flat run_workflow permission before this.
  def test_a_pm_runs_the_bundled_workflow_the_pm_role_owns
    with_tmp_project do
      out, = capture_io do
        Riggs::CLI.start(["workflow:run", "review_prd", "--user", "pm_alice",
                          "--auto-approve", "--input", "prd:one line prd"])
      end

      assert_match(/Review PRD/i, out)
    end
  end

  def test_a_pm_is_refused_a_workflow_the_pm_role_does_not_own
    with_tmp_project do
      _out, err = capture_io do
        assert_raises(SystemExit) do
          Riggs::CLI.start(["workflow:run", "example_triage", "--user", "pm_alice", "--auto-approve"])
        end
      end

      assert_match(/declares no owner_role/, err)
    end
  end

  def test_a_repository_workflow_labelled_pm_is_still_refused_to_a_pm
    with_tmp_project do
      write_project_workflow("repo_task", owner_role: "pm")

      _out, err = capture_io do
        assert_raises(SystemExit) do
          Riggs::CLI.start(["workflow:run", "repo_task", "--user", "pm_alice", "--auto-approve"])
        end
      end

      assert_match(/declared by this repository/, err)
    end
  end

  # Resuming executes, so it needs the same rule as starting -- otherwise a PM
  # resumes an engineer's deploy session. Nothing covered this path: removing
  # its gate left the whole suite green.
  def test_a_pm_cannot_resume_a_session_for_a_workflow_the_pm_does_not_own
    with_tmp_project do
      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      session_id = storage.create_session(
        workflow_name: "example_triage", identity: { id: "eng_bob", memory_namespace: "ns" }
      )
      storage.close

      _out, err = capture_io do
        assert_raises(SystemExit) { Riggs::CLI.start(["workflow:resume", session_id, "--user", "pm_alice"]) }
      end

      assert_match(/declares no owner_role/, err)
    end
  end

  # POST /api/sessions/:id/approve resumes the GraphEngine and runs the
  # remaining steps, so it executes -- but it asked only for approve_gates and
  # never consulted the rule. The same user, refused 403 when STARTING the
  # workflow, ran it to completion by approving it instead. Found by review;
  # my own enumeration of the execution entry points missed this one.
  def test_approving_a_paused_session_cannot_execute_a_workflow_the_role_may_not_run
    with_tmp_project do
      add_global_role("gatekeeper", %w[approve_gates read_workflow inspect_run], user: "gate_gail")
      session_id = paused_session
      app = Rack::MockRequest.new(Riggs::Web::App)

      refused = app.post("/api/sessions/#{session_id}/approve", "HTTP_X_RIGGS_USER" => "gate_gail")

      assert_equal 403, refused.status
      assert_equal 0, executed_steps(session_id), "no step may run for a role that cannot run this workflow"
    end
  end

  def test_an_approver_who_may_run_the_workflow_still_resumes_it
    with_tmp_project do
      session_id = paused_session
      app = Rack::MockRequest.new(Riggs::Web::App)

      allowed = app.post("/api/sessions/#{session_id}/approve", "HTTP_X_RIGGS_USER" => "eng_bob")

      assert_equal 200, allowed.status
      assert_operator executed_steps(session_id), :>, 0, "a permitted approver must still resume the run"
    end
  end

  def test_the_web_run_route_asks_the_same_rule
    with_tmp_project do
      app = Rack::MockRequest.new(Riggs::Web::App)
      headers = { "HTTP_X_RIGGS_USER" => "pm_alice" }

      owned = app.post("/workflows/review_prd/run", headers.merge(params: { "prd" => "one line prd" }))
      refused = app.post("/workflows/example_triage/run", headers)

      assert_equal 302, owned.status
      assert_equal 403, refused.status
      assert_match(/declares no owner_role/, refused.body)
    end
  end

  private

  def add_global_role(role, permissions, user:)
    path = Riggs::Config::Resolver.global_config
    config = Psych.safe_load(File.read(path), aliases: true)
    config["roles"][role] = permissions
    config["users"][user] = { "id" => user, "role" => role }
    File.write(path, Psych.dump(config))
    Riggs::Config::Resolver.reset_cache!
  end

  # example_triage pauses at the `debug` step's approval gate when the
  # classification comes back ERROR, which is the state the approve endpoints
  # exist to act on.
  def paused_session
    engine = Riggs::Workflow::GraphEngine.new(
      workflow: Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml"),
      user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
      db_path: "./db/riggs.sqlite3", hub_config: Riggs::Identity.load_config,
      gate_handler: ->(*) { :paused }, skill_registry: Riggs::SkillRegistry.new
    )
    engine.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })
    engine.session_id
  end

  def executed_steps(session_id)
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    count = storage.list_messages(session_id, step_key: "debug").size
    storage.close
    count
  end

  def write_project_workflow(name, owner_role:)
    dir = Riggs::Triggers.project_workflows_dir
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.yml"), Psych.dump(
                                                "name" => name, "owner_role" => owner_role,
                                                "triggers" => [{ "type" => "manual" }],
                                                "steps" => [{ "id" => "a", "kind" => "prompt", "input" => "hi" }]
                                              ))
  end

  def identity(role, permissions)
    { id: "someone", role: role, permissions: permissions }
  end

  def denial_for(who, owner:, tier:)
    denial = Riggs::WorkflowAccess.denial(
      identity: who, workflow: { name: "review_prd", owner_role: owner }, tier: tier
    )
    refute_nil denial, "expected a denial"
    denial
  end

  def assert_permits(who, owner:, tier:)
    denial = Riggs::WorkflowAccess.denial(
      identity: who, workflow: { name: "review_prd", owner_role: owner }, tier: tier
    )
    assert_nil denial, "expected no denial, got: #{denial}"
  end
end

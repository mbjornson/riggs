# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "json"

class TestWebApp < Minitest::Test
  include Rack::Test::Methods

  def app
    Riggs::Web::App
  end

  def test_health_and_config_get
    with_tmp_project do
      header "X-Riggs-User", "eng_bob"
      get "/health"
      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      assert_equal "eng_bob", body["identity"]

      get "/api/config"
      assert_equal 200, last_response.status
      cfg = JSON.parse(last_response.body)
      assert cfg["providers"]
    end
  end

  def test_config_patch_forbidden_for_viewer
    with_tmp_project do
      header "X-Riggs-User", "view_cara"
      header "Content-Type", "application/json"
      patch "/api/config", JSON.generate("default_user" => "view_cara")
      assert_equal 403, last_response.status
    end
  end

  def test_config_patch_allowed_for_pm
    with_tmp_project do
      header "X-Riggs-User", "pm_alice"
      header "Content-Type", "application/json"
      patch "/api/config", JSON.generate("providers" => { "mock" => { "type" => "mock" }, "x" => { "type" => "mock" } })
      assert_equal 200, last_response.status
      cfg = JSON.parse(last_response.body)
      assert cfg.dig("providers", "x")
    end
  end

  def test_workflows_list_and_run
    with_tmp_project do
      header "X-Riggs-User", "eng_bob"
      get "/api/workflows"
      assert_equal 200, last_response.status
      names = JSON.parse(last_response.body)
      assert_includes names, "example_triage"

      header "Content-Type", "application/json"
      post "/api/workflows/example_triage/run",
           JSON.generate("input" => { "ticket" => "Login ERROR timeout" }, "auto_approve" => true)
      assert_equal 200, last_response.status, last_response.body
      result = JSON.parse(last_response.body)
      assert result["session_id"]
      assert_equal "completed", result["status"]

      get "/api/sessions/#{result['session_id']}"
      assert_equal 200, last_response.status

      get "/api/sessions/#{result['session_id']}/audit"
      assert_equal 200, last_response.status
      audit = JSON.parse(last_response.body)
      assert audit.is_a?(Array)
      assert audit.any?
    end
  end

  def test_hitl_gate_endpoints
    with_tmp_project do
      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      sid = storage.create_session(
        workflow_name: "example_triage",
        user_id: "eng_bob",
        memory_namespace: "eng_bob_private"
      )
      storage.update_session(sid, status: "awaiting_approval")
      storage.close

      header "X-Riggs-User", "eng_bob"
      post "/api/sessions/#{sid}/approve"
      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      assert_equal "approved", body["decision"]

      get "/api/sessions/#{sid}"
      session = JSON.parse(last_response.body)
      assert_equal "approved_pending_resume", session["status"]
    end
  end

  def test_approving_a_paused_session_resumes_the_run
    with_tmp_project do
      paused = pause_a_run

      header "X-Riggs-User", "eng_bob"
      post "/api/sessions/#{paused.session_id}/approve"

      assert_equal 200, last_response.status
      assert_equal "completed", JSON.parse(last_response.body)["status"]

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_equal "completed", storage.find_session(paused.session_id)["status"]
      assert_nil storage.load_resume_state(paused.session_id)
      assert storage.list_messages(paused.session_id, step_key: "debug").any?,
             "the gated step must have executed on resume"
      storage.close
    end
  end

  def test_rejecting_a_paused_session_ends_it_without_resuming
    with_tmp_project do
      paused = pause_a_run

      header "X-Riggs-User", "eng_bob"
      post "/api/sessions/#{paused.session_id}/reject"

      assert_equal 200, last_response.status

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      assert_equal "rejected", storage.find_session(paused.session_id)["status"]
      assert_empty storage.list_messages(paused.session_id, step_key: "debug"),
                   "a rejected gate must not execute the gated step"
      storage.close
    end
  end

  def pause_a_run
    workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
    engine = Riggs::Workflow::GraphEngine.new(
      workflow: workflow,
      user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
      db_path: "./db/riggs.sqlite3",
      hub_config: Riggs::Identity.load_config,
      gate_handler: ->(*) { :paused },
      skill_registry: Riggs::SkillRegistry.new
    )
    engine.execute(StringIO.new, input: { ticket: "Production outage ERROR database down" })
    assert_equal :paused, engine.status
    engine
  end

  def test_dashboard_html
    with_tmp_project do
      header "X-Riggs-User", "pm_alice"
      get "/"
      assert_equal 200, last_response.status
      assert_match(/Riggs/, last_response.body)
      assert_match(/Configuration/, last_response.body)
    end
  end

  def seed_session(status: "running", events: 3)
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    sid = storage.create_session(
      workflow_name: "example_triage",
      user_id: "eng_bob",
      memory_namespace: "eng_bob_private"
    )
    events.times { |i| storage.audit(session_id: sid, event_type: "step_start", payload: { "n" => i }) }
    storage.update_session(sid, status: status)
    storage.close
    sid
  end

  def test_stream_drains_every_page_before_signalling_done
    with_tmp_project do
      sid = seed_session(status: "completed", events: 620)

      with_stream_bounds(timeout: 5, poll: 0.02) do
        header "X-Riggs-User", "eng_bob"
        get "/api/sessions/#{sid}/stream"

        body = last_response.body

        assert_equal 620, body.scan(/^id: /).length,
                     "every audit row must be streamed, not just the first page"
        assert_includes body, "event: done"
      end
    end
  end

  def test_events_endpoint_returns_normalized_events
    with_tmp_project do
      sid = seed_session(events: 3)
      header "X-Riggs-User", "eng_bob"
      get "/api/sessions/#{sid}/events"

      assert_equal 200, last_response.status, last_response.body
      body = JSON.parse(last_response.body)

      assert_equal 3, body["events"].size
      assert_equal sid, body["events"].first["session_id"]
      assert_equal "step_start", body["events"].first["type"]
      assert_equal({ "n" => 0 }, body["events"].first["payload"])
      assert_equal body["events"].last["id"], body["last_id"]
      assert_equal "running", body["status"]
      refute body["done"]
    end
  end

  def test_events_after_filters_strictly_and_empty_page_echoes_after
    with_tmp_project do
      sid = seed_session(events: 3)
      header "X-Riggs-User", "eng_bob"
      get "/api/sessions/#{sid}/events"
      ids = JSON.parse(last_response.body)["events"].map { |e| e["id"] }

      get "/api/sessions/#{sid}/events?after=#{ids[0]}"
      page = JSON.parse(last_response.body)

      assert_equal ids[1..], page["events"].map { |e| e["id"] }
      assert_equal ids.last, page["last_id"]

      get "/api/sessions/#{sid}/events?after=#{ids.last}"
      empty = JSON.parse(last_response.body)

      assert_empty empty["events"]
      assert_equal ids.last, empty["last_id"]
    end
  end

  def test_events_limit_caps_the_page
    with_tmp_project do
      sid = seed_session(events: 3)
      header "X-Riggs-User", "eng_bob"

      get "/api/sessions/#{sid}/events?limit=2"

      assert_equal 2, JSON.parse(last_response.body)["events"].size

      get "/api/sessions/#{sid}/events?limit=0"

      assert_equal 1, JSON.parse(last_response.body)["events"].size

      get "/api/sessions/#{sid}/events?limit=99999"

      assert_equal 3, JSON.parse(last_response.body)["events"].size
    end
  end

  def test_events_limit_clamps_at_one_thousand
    with_tmp_project do
      # 1001 rows, so an unclamped limit would return more than 1000 and this
      # assertion fails; with only a handful of rows it would pass either way.
      sid = seed_session(events: 1001)
      header "X-Riggs-User", "eng_bob"

      get "/api/sessions/#{sid}/events?limit=99999"

      assert_equal 1000, JSON.parse(last_response.body)["events"].size
    end
  end

  def test_events_done_flag_tracks_terminal_status
    with_tmp_project do
      header "X-Riggs-User", "eng_bob"
      { "completed" => true, "failed" => true, "rejected" => true, "running" => false, "paused" => false }
        .each do |status, expected|
          sid = seed_session(status: status, events: 1)
          get "/api/sessions/#{sid}/events"
          body = JSON.parse(last_response.body)

          assert_equal status, body["status"]
          assert_equal expected, body["done"], "done should be #{expected} for #{status}"
        end
    end
  end

  def test_events_unknown_session_is_not_found
    with_tmp_project do
      header "X-Riggs-User", "eng_bob"
      get "/api/sessions/nope-not-a-session/events"

      assert_equal 404, last_response.status
    end
  end

  def test_events_requires_inspect_run
    with_tmp_project do
      sid = seed_session(events: 1)
      write_role_without_inspect_run

      header "X-Riggs-User", "view_cara"
      get "/api/sessions/#{sid}/events"

      assert_equal 200, last_response.status, "viewer holds inspect_run and must be able to read"

      header "X-Riggs-User", "blind_dan"
      get "/api/sessions/#{sid}/events"

      assert_equal 403, last_response.status
    end
  end

  # Every seeded role in test_helper holds inspect_run, so add one that does not.
  def write_role_without_inspect_run
    cfg = Psych.safe_load(File.read(".agent_hubrc"), permitted_classes: [Symbol], aliases: true)
    cfg["users"]["blind_dan"] = {
      "id" => "blind_dan", "name" => "Dan", "role" => "blind", "memory_namespace" => "blind_dan_private"
    }
    cfg["roles"]["blind"] = ["read_workflow"]
    File.write(".agent_hubrc", Psych.dump(cfg))
  end

  def test_stream_endpoint_emits_sse_frames_and_closes_on_terminal_status
    with_tmp_project do
      sid = seed_session(status: "completed", events: 2)
      header "X-Riggs-User", "eng_bob"
      get "/api/sessions/#{sid}/stream"

      assert_equal 200, last_response.status, last_response.body
      assert_equal "text/event-stream", last_response.headers["content-type"]
      assert_equal "no-cache", last_response.headers["cache-control"]
      assert_equal "no", last_response.headers["x-accel-buffering"]

      frames = last_response.body.split("\n\n").reject(&:empty?)

      assert_equal 3, frames.size
      assert_match(/\Aid: \d+\ndata: \{/, frames.first)
      assert_equal({ "n" => 0 }, JSON.parse(frames.first.split("data: ", 2).last)["payload"])
      assert_equal "event: done\ndata: {\"status\":\"completed\"}", frames.last
    end
  end

  def test_stream_endpoint_stops_at_the_wall_clock_cap
    with_tmp_project do
      sid = seed_session(status: "running", events: 1)
      with_stream_bounds(timeout: 0.15, poll: 0.02) do
        header "X-Riggs-User", "eng_bob"
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        get "/api/sessions/#{sid}/stream"
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_equal 200, last_response.status
        assert_operator elapsed, :<, 3.0, "stream must be bounded by its wall-clock cap"
        assert_includes last_response.body, "data: "
        refute_includes last_response.body, "event: done"
      end
    end
  end

  def test_stream_endpoint_honours_after_and_permissions
    with_tmp_project do
      sid = seed_session(status: "completed", events: 3)
      write_role_without_inspect_run
      header "X-Riggs-User", "eng_bob"
      get "/api/sessions/#{sid}/events"
      ids = JSON.parse(last_response.body)["events"].map { |e| e["id"] }

      get "/api/sessions/#{sid}/stream?after=#{ids[1]}"

      assert_equal ["id: #{ids[2]}"], last_response.body.scan(/^id: \d+$/)

      get "/api/sessions/nope-not-a-session/stream"

      assert_equal 404, last_response.status

      header "X-Riggs-User", "blind_dan"
      get "/api/sessions/#{sid}/stream"

      assert_equal 403, last_response.status
    end
  end

  def test_session_page_renders_a_live_event_log
    with_tmp_project do
      sid = seed_session(status: "running", events: 2)
      header "X-Riggs-User", "eng_bob"
      get "/sessions/#{sid}"

      assert_equal 200, last_response.status, last_response.body
      assert_includes last_response.body, "Live events"
      assert_includes last_response.body, "riggs-live-events"
      assert_includes last_response.body, "/api/sessions/#{sid}/events"
      assert_match(/, 2000\)/, last_response.body)
      # The live log resumes from the newest server-rendered audit row.
      assert_includes last_response.body, 'data-last-id="2"'
    end
  end

  def with_stream_bounds(timeout:, poll:)
    Riggs::Web::App.stream_timeout_seconds = timeout
    Riggs::Web::App.stream_poll_seconds = poll
    yield
  ensure
    Riggs::Web::App.stream_timeout_seconds = nil
    Riggs::Web::App.stream_poll_seconds = nil
  end

  def test_viewer_cannot_run
    with_tmp_project do
      header "X-Riggs-User", "view_cara"
      header "Content-Type", "application/json"
      post "/api/workflows/example_triage/run", JSON.generate("input" => {})
      assert_equal 403, last_response.status
    end
  end

  def test_usage_endpoint_reports_totals_with_coverage
    with_tmp_project do
      session_id = create_session_with_usage
      header "X-Riggs-User", "eng_bob"
      get "/api/sessions/#{session_id}/usage"

      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)

      assert_equal 3, body["session"]["calls"]
      assert_equal 1, body["session"]["measured_calls"]
      assert_equal 2, body["steps"].length

      # cli_step's calls are all Usage::EMPTY, so the group's SUM(...) over an
      # all-NULL column must resolve to nil — never 0 — while the call itself
      # still counts. This is the one invariant the whole feature exists for:
      # a step can be fully counted and fully unmeasured at the same time.
      cli_step = body["steps"].find { |s| s["step_key"] == "cli_step" }
      refute_nil cli_step, "expected a cli_step row"
      assert_equal 1, cli_step["calls"]
      assert_nil cli_step["total_tokens"]
      assert_nil cli_step["cost_usd"]
    end
  end

  def test_usage_endpoint_requires_inspect_run
    with_tmp_project do
      session_id = create_session_with_usage
      header "X-Riggs-User", "view_cara"
      get "/api/sessions/#{session_id}/usage"

      assert_equal 200, last_response.status, "viewer holds inspect_run"
    end
  end

  def test_session_page_renders_unmeasured_usage_without_zero
    with_tmp_project do
      session_id = create_session_with_usage
      header "X-Riggs-User", "eng_bob"
      get "/sessions/#{session_id}"

      assert_equal 200, last_response.status, last_response.body
      # cli_step has no measured calls at all, so its Tokens/Cost cells must
      # read "unmeasured"/"unpriced" — a nil-to-0 regression would render a
      # bare "0" here instead, silently claiming a fully-measured zero-token call.
      assert_includes last_response.body, "<td>unmeasured</td>"
      refute_includes last_response.body, "<td>0</td>"
    end
  end

  def test_skills_page_shows_the_description
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/writer")
      File.write("config/riggs/skills/writer/SKILL.md",
                 "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      header "X-Riggs-User", "eng_bob"
      get "/skills"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Writes clearly."
    end
  end

  def test_skills_page_escapes_html_in_the_description
    with_tmp_project do
      # Descriptions come from files Riggs did not author; a skill copied in
      # from another repository could carry markup or a script tag. The
      # single-quoted YAML scalar below (with '' escaping the embedded
      # apostrophes) parses to the literal: <script>alert('xss')</script> & "quotes"
      FileUtils.mkdir_p("config/riggs/skills/writer")
      File.write("config/riggs/skills/writer/SKILL.md", <<~MD)
        ---
        name: writer
        description: '<script>alert(''xss'')</script> & "quotes"'
        ---
        Body.
      MD

      header "X-Riggs-User", "eng_bob"
      get "/skills"

      assert_equal 200, last_response.status
      # CGI.escapeHTML's actual output for this input (verified directly,
      # not guessed): & -> &amp;, " -> &quot;, ' -> &#39;, < -> &lt;, > -> &gt;.
      assert_includes last_response.body,
                      "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt; &amp; &quot;quotes&quot;"
      refute_includes last_response.body, "<script>alert('xss')</script>"
    end
  end

  def create_session_with_usage
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    id = storage.create_session(workflow_name: "example_triage", user_id: "eng_bob", memory_namespace: "ns")
    storage.record_provider_call(
      session_id: id, step_key: "triage", provider: "mock", model: "m", relay_attempt: 1,
      usage: { input_tokens: 10, output_tokens: 5, cache_read_tokens: nil,
               cache_write_tokens: nil, total_tokens: 15, measured: true },
      cost_usd: 0.01
    )
    storage.record_provider_call(
      session_id: id, step_key: "triage", provider: "claude_cli", model: nil, relay_attempt: 1,
      usage: Riggs::Usage::EMPTY, cost_usd: nil
    )
    # A step whose calls are ALL unmeasured, on its own step_key, so the
    # per-step aggregate genuinely resolves to nil rather than summing
    # against a sibling measured call on the same step (the original fixture
    # bug: both calls shared step_key "triage", so total_tokens always
    # resolved to 15 and the nil path was never exercised).
    storage.record_provider_call(
      session_id: id, step_key: "cli_step", provider: "claude_cli", model: nil, relay_attempt: 1,
      usage: Riggs::Usage::EMPTY, cost_usd: nil
    )
    storage.close
    id
  end
end

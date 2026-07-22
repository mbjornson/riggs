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

  def test_dashboard_html
    with_tmp_project do
      header "X-Riggs-User", "pm_alice"
      get "/"
      assert_equal 200, last_response.status
      assert_match(/Riggs/, last_response.body)
      assert_match(/Configuration/, last_response.body)
    end
  end

  def test_viewer_cannot_run
    with_tmp_project do
      header "X-Riggs-User", "view_cara"
      header "Content-Type", "application/json"
      post "/api/workflows/example_triage/run", JSON.generate("input" => {})
      assert_equal 403, last_response.status
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "json"

class TestTriggersSurface < Minitest::Test
  include Rack::Test::Methods

  def app
    Riggs::Web::App
  end

  def test_triggers_match_cli
    with_tmp_project do
      out, = capture_io { Riggs::CLI.start(["triggers:match", "please triage this"]) }
      assert_match(/example_triage/, out)

      out2, = capture_io { Riggs::CLI.start(["triggers:match", "unrelated invoice fluff"]) }
      assert_match(/No playbooks matched/i, out2)
    end
  end

  def test_triggers_list_cli
    with_tmp_project do
      out, = capture_io { Riggs::CLI.start(["triggers:list"]) }
      assert_match(/example_triage/, out)
      assert_match(/keyword/i, out)
    end
  end

  def test_api_triggers_match
    with_tmp_project do
      header "X-Riggs-User", "eng_bob"
      get "/api/triggers/match", q: "please triage this"
      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      assert body.any? { |w| w["name"] == "example_triage" }

      get "/api/triggers/match", q: "zzzz-no-match"
      assert_equal 200, last_response.status
      assert_empty JSON.parse(last_response.body)
    end
  end

  def test_triggers_html_page
    with_tmp_project do
      header "X-Riggs-User", "eng_bob"
      get "/triggers", q: "ticket"
      assert_equal 200, last_response.status
      assert_match(/example_triage/, last_response.body)
    end
  end

  def test_workflow_new_non_interactive
    with_tmp_project do
      capture_io do
        Riggs::CLI.start(
          [
            "workflow:new", "my_playbook",
            "--non-interactive",
            "--trigger=keyword",
            "--keywords=alpha,beta",
            "--user=pm_alice"
          ]
        )
      end
      path = "config/riggs/workflows/my_playbook.yml"
      assert File.exist?(path)
      wf = Riggs::Workflow::Loader.load(path: path)
      assert_equal "my_playbook", wf[:name]
      assert wf[:triggers].any? { |t| t[:type].to_s == "keyword" }
      report = Riggs::Workflow::Loader.validate(wf)
      assert report[:valid], report[:errors].inspect
    end
  end
end

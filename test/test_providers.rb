# frozen_string_literal: true

require "test_helper"

class TestProviders < Minitest::Test
  FakeRunner = Struct.new(:handler) do
    def run(**kwargs)
      handler.call(**kwargs)
    end
  end

  FakeStatus = Struct.new(:ok) do
    def success?
      ok
    end

    def exitstatus
      ok ? 0 : 1
    end
  end

  def test_mock_provider
    mock = Riggs::Providers::Mock.new(name: "mock")
    result = mock.complete(messages: [{ role: "user", content: "hello ERROR world" }])
    assert_match(/ERROR/, result[:content])
  end

  def test_router_failover_with_injectable_registry
    failing = Class.new(Riggs::Providers::Base) do
      define_method(:complete) do |**_|
        raise Riggs::Providers::RateLimitError, "boom"
      end
    end

    router = Riggs::Providers::Router.new(
      registry: {
        "fail" => failing,
        "mock" => Riggs::Providers::Mock
      }
    )
    result = router.call(chain: %w[fail mock], messages: [{ role: "user", content: "hi" }])
    assert_equal "mock", result[:provider]
    assert_equal 2, result[:relay_attempt]
  end

  def test_workflow_providers_merge_into_build
    called_opts = nil
    capturing = Class.new(Riggs::Providers::Base) do
      define_method(:complete) do |**_|
        called_opts = options
        { provider: name, content: "ok", usage: {} }
      end
    end

    router = Riggs::Providers::Router.new(
      hub_providers: { "cursor" => { type: "cursor", model: "from-hub" } },
      workflow_providers: { "cursor" => { model: "from-workflow" } },
      registry: { "cursor" => capturing }
    )
    router.call(chain: ["cursor"], messages: [{ role: "user", content: "x" }])
    assert_equal "from-workflow", called_opts[:model]
  end

  def test_step_provider_named_chain
    step = Riggs::Workflow::StepNode.from_hash(id: "s", provider: "fast")
    workflow = {
      providers: {
        default: { relay_chain: ["mock"] },
        fast: { relay_chain: %w[cursor mock] }
      }
    }
    router = Riggs::Providers::Router.new(
      workflow_providers: workflow[:providers],
      hub_providers: {}
    )
    assert_equal %w[cursor mock], router.chain_for(step: step, workflow: workflow)
  end

  def test_cursor_cli_with_stubbed_runner
    ENV["CURSOR_API_KEY"] = "test-key"
    runner = FakeRunner.new(lambda { |command:, args:, **_|
      assert_equal "agent", command
      assert_includes args, "-p"
      assert_includes args, "--output-format"
      Riggs::Providers::CliRunner::Result.new(
        stdout: "classification=OK",
        stderr: "",
        status: FakeStatus.new(true)
      )
    })

    provider = Riggs::Providers::CursorCli.new(name: "cursor", options: { runner: runner })
    result = provider.complete(messages: [{ role: "user", content: "hi" }])
    assert_equal "classification=OK", result[:content]
    assert_equal "cursor", result[:provider]
  ensure
    ENV.delete("CURSOR_API_KEY")
  end

  def test_claude_cli_with_stubbed_runner
    ENV["ANTHROPIC_API_KEY"] = "sk-test"
    runner = FakeRunner.new(lambda { |command:, args:, **_|
      assert_equal "claude", command
      assert_includes args, "-p"
      assert_includes args, "--bare"
      Riggs::Providers::CliRunner::Result.new(stdout: "hello from claude", stderr: "", status: FakeStatus.new(true))
    })
    provider = Riggs::Providers::ClaudeCli.new(name: "claude_cli", options: { runner: runner })
    result = provider.complete(messages: [{ role: "user", content: "hi" }], system: "be brief")
    assert_equal "hello from claude", result[:content]
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  def test_codex_cli_with_stubbed_runner
    ENV["OPENAI_API_KEY"] = "sk-openai"
    runner = FakeRunner.new(lambda { |command:, args:, env:, **_|
      assert_equal "codex", command
      assert_equal "exec", args.first
      assert_equal "sk-openai", env["CODEX_API_KEY"]
      Riggs::Providers::CliRunner::Result.new(stdout: "codex says hi", stderr: "", status: FakeStatus.new(true))
    })
    provider = Riggs::Providers::CodexCli.new(name: "codex", options: { runner: runner })
    result = provider.complete(messages: [{ role: "user", content: "hi" }])
    assert_equal "codex says hi", result[:content]
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  def test_cursor_cli_requires_api_key
    ENV.delete("CURSOR_API_KEY")
    provider = Riggs::Providers::CursorCli.new(name: "cursor", options: {
      runner: FakeRunner.new(->(**_) { raise "should not run" })
    })
    assert_raises(Riggs::Providers::Error) do
      provider.complete(messages: [{ role: "user", content: "hi" }])
    end
  end

  def test_cli_runner_missing_binary
    assert_raises(Riggs::Providers::Error) do
      Riggs::Providers::CliRunner.run(command: "riggs-nonexistent-binary-xyz", args: [], timeout: 1)
    end
  end

  def test_cursor_cloud_create_and_poll
    ENV["CURSOR_API_KEY"] = "crsr_test"
    calls = []
    http = lambda { |method, path, body|
      calls << [method, path, body]
      case [method, path]
      when [:post, "/v1/agents"]
        {
          "agent" => { "id" => "bc-1", "latestRunId" => "run-1" },
          "run" => { "id" => "run-1", "status" => "CREATING" }
        }
      when [:get, "/v1/agents/bc-1/runs/run-1"]
        { "id" => "run-1", "status" => "FINISHED", "result" => "cloud done", "durationMs" => 12 }
      else
        raise "unexpected #{method} #{path}"
      end
    }

    provider = Riggs::Providers::CursorCloud.new(
      name: "cursor_cloud",
      options: {
        http_client: http,
        repos: [{ url: "https://github.com/org/repo", startingRef: "main" }],
        poll_interval_seconds: 0
      }
    )
    result = provider.complete(messages: [{ role: "user", content: "ship it" }])
    assert_equal "cloud done", result[:content]
    assert_equal "cursor_cloud", result[:provider]
    assert_equal :post, calls.first[0]
  ensure
    ENV.delete("CURSOR_API_KEY")
  end

  def test_cursor_cloud_requires_repos
    ENV["CURSOR_API_KEY"] = "crsr_test"
    provider = Riggs::Providers::CursorCloud.new(name: "cursor_cloud", options: { repos: [] })
    err = assert_raises(Riggs::Providers::Error) do
      provider.complete(messages: [{ role: "user", content: "x" }])
    end
    assert_match(/repos/, err.message)
  ensure
    ENV.delete("CURSOR_API_KEY")
  end

  def test_router_failover_cursor_to_mock
    ENV["CURSOR_API_KEY"] = "crsr_test"
    failing_runner = FakeRunner.new(lambda { |**_|
      raise Riggs::Providers::RateLimitError, "cli 429"
    })

    router = Riggs::Providers::Router.new(
      hub_providers: {
        "cursor" => { type: "cursor", runner: failing_runner },
        "mock" => { type: "mock" }
      }
    )
    # CursorCli receives options including runner from hub config
    result = router.call(chain: %w[cursor mock], messages: [{ role: "user", content: "hi" }])
    assert_equal "mock", result[:provider]
  ensure
    ENV.delete("CURSOR_API_KEY")
  end
end

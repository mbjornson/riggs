# frozen_string_literal: true

require "test_helper"
require "rbconfig"

class TestProviders < Minitest::Test
  FakeRunner = Struct.new(:handler) do
    def run(**)
      handler.call(**)
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

  def test_unknown_provider_name_raises_instead_of_mocking
    router = Riggs::Providers::Router.new
    err = assert_raises(Riggs::Providers::Error) do
      router.call(chain: ["anthorpic"], messages: [{ role: "user", content: "hi" }])
    end
    assert_match(/anthorpic/, err.message)
  end

  def test_unknown_provider_fails_over_to_next_in_chain
    router = Riggs::Providers::Router.new
    result = router.call(chain: %w[anthorpic mock], messages: [{ role: "user", content: "hi" }])
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

  def test_cli_runner_kills_child_on_timeout
    Dir.mktmpdir do |dir|
      pid_file = File.join(dir, "pid")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Riggs::Providers::TimeoutError) do
        Riggs::Providers::CliRunner.run(
          command: RbConfig.ruby,
          args: ["-e", "File.write(ARGV[0], Process.pid); sleep 15", pid_file],
          timeout: 1
        )
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 5, "run must return promptly on timeout, took #{elapsed.round(1)}s"

      pid = File.read(pid_file).to_i
      dead = false
      20.times do
        Process.kill(0, pid)
        sleep 0.05
      rescue Errno::ESRCH
        dead = true
        break
      end
      assert dead, "child process #{pid} still running after timeout"
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

  def test_cursor_cloud_completes_through_router_when_tools_present
    ENV["CURSOR_API_KEY"] = "crsr_test"
    http = lambda { |method, path, _body|
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

    router = Riggs::Providers::Router.new(
      hub_providers: {
        "cursor_cloud" => {
          type: "cursor_cloud",
          http_client: http,
          repos: [{ url: "https://github.com/org/repo" }],
          poll_interval_seconds: 0
        }
      }
    )
    result = router.call(
      chain: ["cursor_cloud"],
      messages: [{ role: "user", content: "ship it" }],
      tools: [{ name: "lookup_runbook", description: "d", input_schema: { type: "object" } }]
    )
    assert_equal "cloud done", result[:content]
    assert_equal "cursor_cloud", result[:provider]
  ensure
    ENV.delete("CURSOR_API_KEY")
  end

  def test_cursor_cloud_request_uses_bearer_auth
    provider = Riggs::Providers::CursorCloud.new(name: "cursor_cloud", options: {})
    req = provider.send(:build_request, :post, URI("https://api.cursor.com/v1/agents"), api_key: "crsr_k", body: {})
    assert_equal "Bearer crsr_k", req["authorization"]
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

  def test_mock_tool_calls_when_tools_present
    mock = Riggs::Providers::Mock.new(name: "mock")
    tools = [{ name: "lookup_runbook", description: "x", input_schema: {} }]
    result = mock.complete(
      messages: [{ role: "user", content: "please lookup runbook for oauth" }],
      tools: tools
    )
    refute_empty result[:tool_calls]
    assert_equal "lookup_runbook", result[:tool_calls].first[:name]
  end

  def test_anthropic_includes_tools_in_body
    captured = nil
    provider = Riggs::Providers::Anthropic.new(
      name: "claude",
      options: {
        api_key: "sk-test",
        http_client: lambda { |body|
          captured = body
          {
            provider: "claude",
            content: "ok",
            tool_calls: [],
            usage: {},
            raw: {}
          }
        }
      }
    )
    provider.complete(
      messages: [{ role: "user", content: "hi" }],
      tools: [{ name: "lookup_runbook", description: "d", input_schema: { type: "object" } }]
    )
    assert captured[:tools]
    assert_equal "lookup_runbook", captured[:tools].first[:name]
  end

  def test_mock_provider_reports_its_model
    provider = Riggs::Providers::Mock.new(name: "mock", options: { model: "mock-1" })

    result = provider.complete(messages: [{ role: "user", content: "hi" }])

    assert_equal "mock-1", result[:model]
  end

  def test_mock_provider_model_is_nil_when_unconfigured
    provider = Riggs::Providers::Mock.new(name: "mock", options: {})

    result = provider.complete(messages: [{ role: "user", content: "hi" }])

    assert result.key?(:model), "the result must carry a :model key even when unconfigured"
    assert_nil result[:model]
  end

  def test_anthropic_prefers_the_model_echoed_by_the_response
    parsed = Riggs::Providers::Anthropic
             .new(name: "anthropic", options: { model: "claude-alias-latest" })
             .send(:parse_anthropic_content,
                   { "content" => [{ "type" => "text", "text" => "ok" }],
                     "model" => "claude-resolved-20260101", "usage" => {} })

    assert_equal "claude-resolved-20260101", parsed[:model],
                 "the echoed model resolves aliases and must win over the configured value"
  end

  def test_anthropic_falls_back_to_the_configured_model
    parsed = Riggs::Providers::Anthropic
             .new(name: "anthropic", options: { model: "claude-configured" })
             .send(:parse_anthropic_content,
                   { "content" => [{ "type" => "text", "text" => "ok" }], "usage" => {} })

    assert_equal "claude-configured", parsed[:model]
  end
end

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
    provider = Riggs::Providers::CodexCli.new(name: "codex", options: { runner: runner, auth: "api" })
    result = provider.complete(messages: [{ role: "user", content: "hi" }])
    assert_equal "codex says hi", result[:content]
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  # auth_mode decides whether Riggs scrubs API keys before handing control to
  # the CLI. An unrecognized value must not fall back to a default, because
  # both defaults spend money -- one from the wrong account.
  def auth_provider(value)
    Riggs::Providers::CodexCli.new(name: "codex", options: { auth: value })
  end

  def test_auth_mode_defaults_to_subscription
    assert_equal "subscription", Riggs::Providers::CodexCli.new(name: "codex", options: {}).auth_mode
    assert_equal "subscription", auth_provider(nil).auth_mode
    assert_equal "subscription", auth_provider("").auth_mode
    assert_equal "subscription", auth_provider("   ").auth_mode
  end

  def test_auth_mode_accepts_api
    assert_equal "api", auth_provider("api").auth_mode
  end

  def test_auth_mode_is_case_insensitive_and_trims
    assert_equal "api", auth_provider("  API  ").auth_mode
    assert_equal "subscription", auth_provider("Subscription").auth_mode
  end

  def test_an_unknown_auth_mode_raises_naming_the_provider_and_the_valid_values
    err = assert_raises(Riggs::Providers::Error) { auth_provider("subscribe").auth_mode }

    assert_match(/codex/, err.message, "the error must name which provider is misconfigured")
    assert_match(/subscription/, err.message, "and list the values that would have worked")
    assert_match(/api/, err.message)
  end

  # Non-CLI providers have no CLI to defer to, so they are always "api".
  def test_router_reports_auth_mode_per_configured_provider
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "codex" => { "type" => "codex" },
        "claude_api" => { "type" => "claude_cli", "auth" => "api" },
        "openai" => { "type" => "openai" }
      }
    )

    assert_equal({ "claude_api" => "api", "codex" => "subscription", "openai" => "api" },
                 router.auth_modes)
  end

  def test_router_auth_modes_sees_workflow_level_overrides
    router = Riggs::Providers::Router.new(
      hub_providers: { "codex" => { "type" => "codex" } },
      workflow_providers: { "codex" => { "auth" => "api" } }
    )

    assert_equal({ "codex" => "api" }, router.auth_modes)
  end

  # Spec R9.1: `auth:` on a non-CLI provider is ignored, not an error -- there
  # is no CLI to defer to, so validating the value would reject a harmless
  # stray key.
  def test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated
    router = Riggs::Providers::Router.new(
      hub_providers: { "openai" => { "type" => "openai", "auth" => "nonsense" } }
    )

    assert_equal({ "openai" => "api" }, router.auth_modes)
  end

  # Deliberate deviation from the brief (see task-4-report.md): auth_modes is
  # an observability field and must not be able to abort a run over a
  # provider that field never dispatches. A CLI provider that is actually
  # used still raises from Cli#auth_mode inside child_env -- untouched by
  # this rescue -- so this gives up nothing on the money-safety axis Task 1
  # built. The rescue is per provider name, so one bad entry must not blank
  # out the others -- that's what the "codex" assertion below proves.
  def test_router_auth_modes_marks_an_invalid_value_without_raising_or_dropping_the_rest
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "codex" => { "type" => "codex", "auth" => "api" },
        "claude_cli" => { "type" => "claude_cli", "auth" => "subscribe" }
      }
    )

    modes = router.auth_modes

    assert_equal "api", modes["codex"], "a good entry must resolve normally, not be swallowed by a sibling's rescue"
    assert_equal "invalid", modes["claude_cli"]
  end

  # The regression this phase exists to fix: a CLI that is logged in via its
  # own subscription must be usable, and Riggs refused to even spawn it.
  def test_cursor_cli_runs_without_an_api_key
    ENV.delete("CURSOR_API_KEY")
    runner = FakeRunner.new(lambda { |**_|
      Riggs::Providers::CliRunner::Result.new(stdout: "ok", stderr: "", status: FakeStatus.new(true))
    })
    provider = Riggs::Providers::CursorCli.new(name: "cursor", options: { runner: runner })

    result = provider.complete(messages: [{ role: "user", content: "hi" }])

    assert_equal "ok", result[:content]
  end

  def test_codex_cli_runs_without_an_api_key
    ENV.delete("CODEX_API_KEY")
    ENV.delete("OPENAI_API_KEY")
    runner = FakeRunner.new(lambda { |**_|
      Riggs::Providers::CliRunner::Result.new(stdout: "ok", stderr: "", status: FakeStatus.new(true))
    })
    provider = Riggs::Providers::CodexCli.new(name: "codex", options: { runner: runner })

    assert_equal "ok", provider.complete(messages: [{ role: "user", content: "hi" }])[:content]
  end

  # Captures the env handed to the runner so the scrub can be asserted without
  # spawning anything.
  def env_handed_to_runner(klass, name:, options: {})
    captured = nil
    runner = FakeRunner.new(lambda { |env:, **_|
      captured = env
      Riggs::Providers::CliRunner::Result.new(stdout: "ok", stderr: "", status: FakeStatus.new(true))
    })
    klass.new(name: name, options: options.merge(runner: runner))
         .complete(messages: [{ role: "user", content: "hi" }])
    captured
  end

  # A nil value means "unset this variable in the child" (Process.spawn
  # contract), which CliRunner's ENV.to_h.merge(env) carries through. This is
  # what stops an exported ANTHROPIC_API_KEY from overriding a Max
  # subscription -- documented Claude Code behavior, and the reason relaxing
  # the pre-flight alone would have been unsafe.
  def test_claude_cli_scrubs_the_api_key_under_subscription
    ENV["ANTHROPIC_API_KEY"] = "sk-test"
    env = env_handed_to_runner(Riggs::Providers::ClaudeCli, name: "claude_cli")

    assert env.key?("ANTHROPIC_API_KEY"), "the key must be present in the hash so it can be unset"
    assert_nil env["ANTHROPIC_API_KEY"], "and nil so the child does not receive it"
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  def test_claude_cli_passes_the_api_key_under_api_mode
    ENV["ANTHROPIC_API_KEY"] = "sk-test"
    env = env_handed_to_runner(Riggs::Providers::ClaudeCli, name: "claude_cli", options: { auth: "api" })

    assert_equal "sk-test", env["ANTHROPIC_API_KEY"]
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  # CLAUDE_CODE_OAUTH_TOKEN is itself a subscription credential -- the
  # documented path for non-interactive use -- so scrubbing it would defeat
  # the mode that is meant to use it.
  def test_claude_cli_keeps_the_oauth_token_under_subscription
    ENV["CLAUDE_CODE_OAUTH_TOKEN"] = "oauth-test"
    env = env_handed_to_runner(Riggs::Providers::ClaudeCli, name: "claude_cli")

    assert_equal "oauth-test", env["CLAUDE_CODE_OAUTH_TOKEN"]
  ensure
    ENV.delete("CLAUDE_CODE_OAUTH_TOKEN")
  end

  def test_codex_cli_scrubs_both_key_variables_under_subscription
    ENV["OPENAI_API_KEY"] = "sk-openai"
    ENV["CODEX_API_KEY"] = "sk-codex"
    env = env_handed_to_runner(Riggs::Providers::CodexCli, name: "codex")

    assert env.key?("CODEX_API_KEY"), "the key must be present in the hash so it can be unset"
    assert_nil env["CODEX_API_KEY"], "and nil so the child does not receive it"
    assert env.key?("OPENAI_API_KEY"), "the key must be present in the hash so it can be unset"
    assert_nil env["OPENAI_API_KEY"], "and nil so the child does not receive it"
  ensure
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("CODEX_API_KEY")
  end

  def test_cursor_cli_scrubs_the_api_key_under_subscription
    ENV["CURSOR_API_KEY"] = "sk-cursor"
    env = env_handed_to_runner(Riggs::Providers::CursorCli, name: "cursor")

    assert env.key?("CURSOR_API_KEY"), "the key must be present in the hash so it can be unset"
    assert_nil env["CURSOR_API_KEY"], "and nil so the child does not receive it"
  ensure
    ENV.delete("CURSOR_API_KEY")
  end

  # Passing the key as an argv flag would hand it to the CLI through a channel
  # the env scrub cannot reach.
  def test_cursor_cli_omits_the_api_key_flag_under_subscription
    captured = nil
    runner = FakeRunner.new(lambda { |args:, **_|
      captured = args
      Riggs::Providers::CliRunner::Result.new(stdout: "ok", stderr: "", status: FakeStatus.new(true))
    })
    Riggs::Providers::CursorCli.new(name: "cursor", options: { runner: runner, api_key: "sk-inline" })
                               .complete(messages: [{ role: "user", content: "hi" }])

    refute_includes captured, "--api-key"
    refute_includes captured, "sk-inline"
  end

  def test_cursor_cli_includes_the_api_key_flag_under_api_mode
    captured = nil
    runner = FakeRunner.new(lambda { |args:, **_|
      captured = args
      Riggs::Providers::CliRunner::Result.new(stdout: "ok", stderr: "", status: FakeStatus.new(true))
    })
    Riggs::Providers::CursorCli.new(
      name: "cursor", options: { runner: runner, api_key: "sk-inline", auth: "api" }
    ).complete(messages: [{ role: "user", content: "hi" }])

    assert_includes captured, "--api-key"
    assert_includes captured, "sk-inline"
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

  # "Not logged in" is the error an operator will hit most often now that the
  # pre-flight is gone. It gets its own class so a failed run says which
  # problem it was, rather than looking like a crash.
  def test_cli_runner_raises_auth_error_on_a_not_logged_in_failure
    err = assert_raises(Riggs::Providers::AuthError) do
      Riggs::Providers::CliRunner.run(
        command: "sh", args: ["-c", "echo 'Not logged in. Run codex login.' >&2; exit 1"]
      )
    end

    assert_match(/Not logged in/, err.message, "the CLI's own words must survive")
  end

  # AuthError must stay a subclass of Error: Router rescues
  # `RateLimitError, TimeoutError, Error` in one clause and relays to the next
  # provider. A sibling class would propagate and kill the run instead.
  def test_auth_error_is_an_error_so_the_relay_chain_still_falls_through
    assert_operator Riggs::Providers::AuthError, :<, Riggs::Providers::Error
  end

  def test_a_rate_limited_failure_is_still_a_rate_limit_error
    assert_raises(Riggs::Providers::RateLimitError) do
      Riggs::Providers::CliRunner.run(
        command: "sh", args: ["-c", "echo '429 too many requests' >&2; exit 1"]
      )
    end
  end

  def test_an_ordinary_failure_is_still_a_plain_error
    err = assert_raises(Riggs::Providers::Error) do
      Riggs::Providers::CliRunner.run(command: "sh", args: ["-c", "echo 'segfault' >&2; exit 3"])
    end

    refute_instance_of Riggs::Providers::AuthError, err
    refute_instance_of Riggs::Providers::RateLimitError, err
  end

  # The subclassing above is only meaningful if the relay actually falls
  # through, so assert the behavior and not just the class hierarchy.
  def test_router_relays_past_a_provider_that_is_not_authenticated
    unauthenticated = Class.new(Riggs::Providers::Base) do
      def complete(**)
        raise Riggs::Providers::AuthError, "CLI not authenticated: codex: Not logged in"
      end
    end
    router = Riggs::Providers::Router.new(
      hub_providers: { "broken" => { "type" => "broken" }, "mock" => { "type" => "mock" } },
      registry: { "broken" => unauthenticated, "mock" => Riggs::Providers::Mock }
    )

    result = router.call(chain: %w[broken mock], messages: [{ role: "user", content: "hi" }])

    assert_equal "mock", result[:provider], "an unauthenticated provider must fail over, not kill the run"
    assert_equal 2, result[:relay_attempt]
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

  # A provider that reports a real vendor-shaped usage block. The mock provider
  # deliberately reports none (it has no tokenizer and must not invent counts),
  # so metering tests need something that does.
  def metered_provider
    Class.new(Riggs::Providers::Base) do
      def complete(**)
        raw = { prompt_tokens: 5, completion_tokens: 7 }
        { provider: name, model: options[:model], content: "ok", tool_calls: [],
          usage: raw, raw: { usage: raw } }
      end
    end
  end

  def metered_router(opts = {})
    Riggs::Providers::Router.new(
      hub_providers: { metered: { type: "metered" }.merge(opts) },
      registry: { "metered" => metered_provider }
    )
  end

  def test_router_normalizes_usage_on_the_result
    result = metered_router.call(chain: ["metered"], messages: [{ role: "user", content: "hello" }])

    assert result[:usage][:measured]
    assert_kind_of Integer, result[:usage][:total_tokens]
  end

  def test_router_prices_a_call_using_hubrc_overrides
    router = metered_router(model: "priced-model",
                            pricing: { "priced-model" => { input: 1000.0, output: 1000.0 } })

    result = router.call(chain: ["metered"], messages: [{ role: "user", content: "hello" }])

    refute_nil result[:cost_usd]
    assert result[:cost_usd].positive?
  end

  def test_router_cost_is_nil_for_an_unpriced_model
    router = metered_router(model: "unpriced-xyz")

    result = router.call(chain: ["metered"], messages: [{ role: "user", content: "hello" }])

    assert result[:usage][:measured], "tokens still record even when the model has no price"
    assert_nil result[:cost_usd]
  end

  def test_router_replaces_vendor_usage_but_preserves_it_under_raw
    result = metered_router.call(chain: ["metered"], messages: [{ role: "user", content: "hello" }])

    # The normalized shape uses canonical names...
    assert_includes result[:usage].keys, :input_tokens
    refute_includes result[:usage].keys, :prompt_tokens
    # ...while raw keeps the vendor's own.
    assert_includes result[:raw][:usage].keys, :prompt_tokens
    assert_equal 5, result[:raw][:usage][:prompt_tokens]
  end

  # R2.7: usage belongs to the provider that answered, not the first one tried.
  def test_router_attributes_usage_to_the_provider_that_answered
    failing = Class.new(Riggs::Providers::Base) do
      def complete(**)
        raise Riggs::Providers::RateLimitError, "429"
      end
    end
    router = Riggs::Providers::Router.new(
      hub_providers: { flaky: { type: "flaky" }, metered: { type: "metered" } },
      registry: { "flaky" => failing, "metered" => metered_provider }
    )

    result = router.call(chain: %w[flaky metered], messages: [{ role: "user", content: "hello" }])

    assert_equal "metered", result[:provider]
    assert_equal 2, result[:relay_attempt]
    assert result[:usage][:measured], "the answering provider's usage is what gets recorded"
  end

  # The mock provider counted string LENGTHS and shipped them as measured token
  # counts, so every mock run reported ~4x-inflated "measured" tokens and the
  # demo workflow displayed character counts wearing a token label.
  def test_mock_reports_no_measured_usage
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })

    result = router.call(chain: ["mock"], messages: [{ role: "user", content: "hello" }])

    refute result[:usage][:measured], "mock has no tokenizer and must not claim measured tokens"
    assert_nil result[:usage][:total_tokens]
  end

  # Coverage is per-call, so a provider that measures some turns and not others
  # reports a fraction no operator can act on. Mock reports none, uniformly.
  def test_mock_reports_no_usage_on_every_branch
    provider = Riggs::Providers::Mock.new(name: "mock", options: {})
    tools = [{ name: "lookup_runbook", description: "x" }]
    branches = [
      provider.complete(messages: [{ role: "user", content: "please lookup the runbook" }], tools: tools),
      provider.complete(messages: [{ role: "user", content: "database down" }]),
      provider.complete(messages: [{ role: "user", content: "hello" }])
    ]

    branches.each do |result|
      normalized = Riggs::Usage.normalize(result[:usage])

      refute normalized[:measured], "every mock branch must report the same (absent) usage"
      assert_nil normalized[:total_tokens]
    end
  end
end

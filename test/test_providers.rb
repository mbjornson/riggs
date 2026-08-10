# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "socket"

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

  def test_provider_classes_declare_their_own_auth_vocabularies_and_defaults
    expectations = {
      Riggs::Providers::Cli => [%w[subscription api], "subscription"],
      Riggs::Providers::OpenAICompatible => [%w[api none], "api"],
      Riggs::Providers::Anthropic => [%w[api], "api"],
      Riggs::Providers::CursorCloud => [%w[api], "api"],
      Riggs::Providers::Mock => [%w[none], "none"]
    }

    expectations.each do |klass, (modes, default)|
      assert_equal modes, klass.auth_modes, "#{klass} must publish only modes it can honor"
      assert_equal default, klass.default_auth_mode
    end
  end

  # const_set, NOT `AUTH_MODES = ...` inside the block. A constant assigned in
  # a Class.new block binds to the block's LEXICAL scope -- Object -- not to the
  # anonymous class. Verified: the anonymous class does not own the constant,
  # `self::AUTH_MODES` then finds Base's copy, and this test fails with
  # ["api"] against a CORRECT implementation while also leaking AUTH_MODES onto
  # Object. const_set assigns on the receiver, so the subclass owns it and the
  # bare-constant bug this test exists to catch still returns ["api"].
  def test_base_reads_subclass_auth_constants_not_its_lexical_constants
    local_only = Class.new(Riggs::Providers::Base) do
      const_set(:AUTH_MODES, %w[none].freeze)
      const_set(:DEFAULT_AUTH_MODE, "none")
    end

    assert_equal %w[none], local_only.auth_modes
    assert_equal "none", local_only.default_auth_mode
    assert_equal "none", local_only.resolve_auth_mode(nil, provider: "local")
    assert_equal "none", local_only.resolve_auth_mode(" NONE ", provider: "local")
    err = assert_raises(Riggs::Providers::Error) { local_only.resolve_auth_mode("api", provider: "local") }
    assert_match(/local/, err.message)
    assert_match(/none/, err.message)
  end

  def test_subclass_without_default_auth_mode_raises_on_omitted_auth
    klass = Class.new(Riggs::Providers::Base) do
      const_set(:AUTH_MODES, %w[none].freeze)
    end

    err = assert_raises(Riggs::Providers::Error) { klass.resolve_auth_mode(nil, provider: "local") }
    assert_match(/DEFAULT_AUTH_MODE/, err.message)
    assert_match(/AUTH_MODES/, err.message)
    refute_match(/provider 'local'/, err.message,
                 "a bad default is a class bug, not an operator typo")
  end

  def test_every_real_provider_resolves_its_default_auth_mode
    classes = [
      Riggs::Providers::Cli,
      Riggs::Providers::OpenAICompatible,
      Riggs::Providers::Anthropic,
      Riggs::Providers::CursorCloud,
      Riggs::Providers::Mock,
      Riggs::Providers::ClaudeCli,
      Riggs::Providers::CodexCli,
      Riggs::Providers::CursorCli
    ]

    classes.each do |klass|
      assert klass.auth_modes.include?(klass.default_auth_mode),
             "#{klass} default must be in its AUTH_MODES"
      assert_equal klass.default_auth_mode, klass.resolve_auth_mode(nil, provider: "test")
    end
  end

  def test_non_cli_instances_resolve_their_own_defaults
    assert_equal "api", Riggs::Providers::OpenAICompatible.new(name: "openai", options: {}).auth_mode
    assert_equal "api", Riggs::Providers::Anthropic.new(name: "anthropic", options: {}).auth_mode
    assert_equal "api", Riggs::Providers::CursorCloud.new(name: "cursor_cloud", options: {}).auth_mode
    assert_equal "none", Riggs::Providers::Mock.new(name: "mock", options: {}).auth_mode
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

  # R9.5 fix (see task-4-report.md): providers.default is the documented way
  # to declare a workflow's relay chain, not a provider -- #chain_for never
  # dispatches it, only unpacks its relay_chain into other providers' names,
  # so it never appears in riggs_provider_calls.provider and does not belong
  # in this map. Both halves matter: absence alone would pass if the filter
  # were too aggressive and dropped real entries along with the routing key.
  def test_auth_modes_excludes_the_default_routing_alias_but_keeps_real_providers
    router = Riggs::Providers::Router.new(
      hub_providers: { "mock" => { "type" => "mock" } },
      workflow_providers: { "default" => { "relay_chain" => ["mock"] } }
    )

    modes = router.auth_modes

    refute_includes modes.keys, "default", "providers.default is a routing directive, not a provider"
    assert_equal "none", modes["mock"], "a real provider in the same providers: block must still be reported"
  end

  def test_registry_entry_without_resolve_auth_mode_is_skipped_by_auth_modes_and_dispatches
    custom = Class.new do
      define_method(:initialize) do |name:, options: {}|
        @name = name.to_s
        @options = options || {}
      end
      attr_reader :name, :options

      define_method(:complete) do |**_|
        { provider: name, content: "custom-ok", usage: {} }
      end
    end

    router = Riggs::Providers::Router.new(
      hub_providers: { "custom" => { "type" => "custom" } },
      registry: { "custom" => custom }
    )

    modes = router.auth_modes
    refute_includes modes.keys, "custom", "custom providers have no auth vocabulary to report"

    result = router.call(chain: ["custom"], messages: [{ role: "user", content: "hi" }])
    assert_equal "custom", result[:provider]
    assert_equal "custom-ok", result[:content]
  end

  def test_an_unsupported_auth_mode_on_openai_compatible_fails_before_relaying
    fallback_called = false
    fallback = Class.new(Riggs::Providers::Base) do
      define_method(:complete) do |**_|
        fallback_called = true
        { provider: name, content: "unexpected", usage: {} }
      end
    end
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "local" => { "type" => "openai", "auth" => "subscription" },
        "fallback" => { "type" => "fallback" }
      },
      registry: { "openai" => Riggs::Providers::OpenAICompatible, "fallback" => fallback }
    )

    err = assert_raises(Riggs::Providers::Error) do
      router.call(messages: [{ role: "user", content: "hi" }], chain: %w[local fallback])
    end

    assert_match(/local/, err.message)
    assert_match(/api, none/, err.message)
    refute fallback_called, "bad auth must fail before any relay provider dispatches"
  end

  # A provider that is only ever named inside a relay_chain still gets
  # dispatched -- #build resolves it from BUILTINS with no config entry of its
  # own -- and riggs_provider_calls records it by name. Leaving it out of the
  # map made the map EMPTY for the commonest workflow shape there is: a
  # providers: block holding nothing but default.relay_chain. That is exactly
  # when the join the map exists for is needed.
  def test_auth_modes_covers_a_provider_named_only_in_a_relay_chain
    router = Riggs::Providers::Router.new(
      workflow_providers: { "default" => { "relay_chain" => ["codex"] } }
    )

    modes = router.auth_modes

    assert_equal "subscription", modes["codex"], "a chain member with no config entry of its own still bills someone"
    refute_includes modes.keys, "default", "the routing directive itself is still not a provider"
  end

  # The chain member and the configured entry are two different sources of
  # names; a fix that reported chain members must not lose the explicit entry's
  # own auth mode, so both halves are asserted here.
  def test_auth_modes_keeps_explicit_entries_while_adding_chain_members
    router = Riggs::Providers::Router.new(
      hub_providers: { "claude_api" => { "type" => "claude_cli", "auth" => "api" } },
      workflow_providers: { "default" => { "relay_chain" => %w[codex claude_api] } }
    )

    modes = router.auth_modes

    assert_equal "subscription", modes["codex"]
    assert_equal "api", modes["claude_api"], "an explicit entry's declared mode must survive being named in a chain"
  end

  # Spec Decision 2: a typo like `auth: subscrption` must not silently fall
  # back to something that spends money. It did. Cli#auth_mode raises
  # Providers::Error from inside child_env, but #call's dispatch loop rescues
  # Error and RELAYS -- so [claude_cli(typo), anthropic] answered on anthropic
  # and billed ANTHROPIC_API_KEY. Validation has to happen outside that rescue.
  def test_an_invalid_auth_mode_fails_the_run_instead_of_relaying_to_a_billed_provider
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "claude_cli" => { "type" => "claude_cli", "auth" => "subscrption" },
        "mock" => { "type" => "mock" }
      }
    )

    err = assert_raises(Riggs::Providers::Error) do
      router.call(messages: [{ role: "user", content: "hi" }], chain: %w[claude_cli mock])
    end

    assert_match(/claude_cli/, err.message)
    refute_match(/All providers in relay_chain failed/, err.message,
                 "the run must fail on the bad config, not after burning the whole chain")
  end

  # Every name #call is handed is a name it will hand to #build, so a
  # `relay_chain` key on that entry does not make it a routing directive here
  # -- it is still dispatched. Skipping validation for it reopened the exact
  # relay-on-typo hole the guard exists to close: reproduced answering on the
  # next provider at attempt 2. The relay_chain skip belongs in
  # #provider_auth_mode, which enumerates config and must tell directives from
  # providers; it does not belong in the guard, where every name is by
  # definition dispatchable.
  def test_an_invalid_auth_mode_is_caught_even_when_the_entry_also_carries_a_relay_chain
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "weird" => { "type" => "claude_cli", "auth" => "subscrption", "relay_chain" => ["mock"] },
        "mock" => { "type" => "mock" }
      }
    )

    err = assert_raises(Riggs::Providers::Error) do
      router.call(messages: [{ role: "user", content: "hi" }], chain: %w[weird mock])
    end

    assert_match(/weird/, err.message)
  end

  def test_a_valid_none_mode_still_dispatches_with_the_auth_guard_in_place
    router = Riggs::Providers::Router.new(
      hub_providers: { "mock" => { "type" => "mock", "auth" => "none" } }
    )

    result = router.call(messages: [{ role: "user", content: "hi" }], chain: ["mock"])

    assert_equal "mock", result[:provider]
  end

  def test_router_auth_modes_rejects_a_configured_invalid_value
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "codex" => { "type" => "codex", "auth" => "api" },
        "claude_cli" => { "type" => "claude_cli", "auth" => "subscribe" }
      }
    )

    modes = router.auth_modes

    assert_equal "api", modes["codex"]
    assert_equal "invalid", modes["claude_cli"]
  end

  def test_a_dormant_misconfigured_provider_does_not_abort_dispatch_on_an_unrelated_chain
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "mock" => { "type" => "mock", "auth" => "none" },
        "anthropic" => { "type" => "anthropic", "auth" => "none" }
      }
    )

    result = router.call(messages: [{ role: "user", content: "hi" }], chain: ["mock"])

    assert_equal "mock", result[:provider]
  end

  def test_anthropic_and_cursor_cloud_reject_none_with_their_own_supported_modes
    { "anthropic" => "anthropic", "cursor_cloud" => "cursor_cloud" }.each do |name, type|
      router = Riggs::Providers::Router.new(
        hub_providers: { name => { "type" => type, "auth" => "none" } }
      )

      err = assert_raises(Riggs::Providers::Error) do
        router.call(messages: [{ role: "user", content: "hi" }], chain: [name])
      end

      assert_match(/#{name}/, err.message)
      assert_match(/api/, err.message)
    end
  end

  def test_provider_auth_modes_omits_a_name_that_resolves_to_no_class
    router = Riggs::Providers::Router.new(
      workflow_providers: { "default" => { "relay_chain" => ["does_not_exist"] } }
    )

    assert_equal({}, router.auth_modes)
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

  # Restores parent ENV after setting test values, including when assertions fail.
  def with_saved_env(vars)
    saved = {}
    vars.each do |key, value|
      saved[key] = ENV[key] if ENV.key?(key)
      ENV[key] = value
    end
    yield
  ensure
    vars.each_key do |key|
      if saved.key?(key)
        ENV[key] = saved[key]
      else
        ENV.delete(key)
      end
    end
  end

  # Shell probe that reports presence without printing secret values.
  def subscription_env_probe_script(var_names)
    Array(var_names).map do |var|
      "if [ -n \"${#{var}+set}\" ]; then echo #{var}=present; else echo #{var}=absent; fi"
    end.join("\n")
  end

  def parse_env_probe(stdout)
    stdout.each_line.to_h do |line|
      key, status = line.strip.split("=", 2)
      [key, status]
    end
  end

  def with_capturing_openai_server
    server = TCPServer.new("127.0.0.1", 0)
    headers_seen = Queue.new
    thread = Thread.new do
      client = server.accept
      request = +""
      request << client.readpartial(1024) until request.include?("\r\n\r\n")
      headers, body = request.split("\r\n\r\n", 2)
      content_length = headers[/^Content-Length:\s*(\d+)/i, 1].to_i
      body ||= ""
      body << client.readpartial(1024) while body.bytesize < content_length

      response_body = JSON.generate(
        "model" => "local-test",
        "choices" => [{ "message" => { "content" => "ok" } }],
        "usage" => {}
      )
      client.write(
        "HTTP/1.1 200 OK\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{response_body.bytesize}\r\n" \
        "Connection: close\r\n\r\n" \
        + response_body
      )
      headers_seen << headers
    ensure
      client&.close
    end

    yield "http://127.0.0.1:#{server.addr[1]}/v1", headers_seen
  ensure
    server&.close
    thread&.join
  end

  def test_openai_compatible_none_sends_no_authorization_header_to_a_real_local_server
    with_saved_env("OPENAI_API_KEY" => "sk-parent-key", "OLLAMA_API_KEY" => "sk-ollama-key") do
      with_capturing_openai_server do |base_url, headers_seen|
        provider = Riggs::Providers::OpenAICompatible.new(
          name: "local",
          options: {
            base_url: base_url,
            model: "local-test",
            auth: "none",
            api_key: "sk-inline-key"
          }
        )

        assert_equal "ok", provider.complete(messages: [{ role: "user", content: "hi" }])[:content]
        refute_match(/^Authorization:/i, headers_seen.pop,
                     "auth: none must keep every credential source off the wire")
      end
    end
  end

  def test_openai_compatible_api_still_sends_the_parent_key_to_a_real_local_server
    with_saved_env("OPENAI_API_KEY" => "sk-parent-key") do
      with_capturing_openai_server do |base_url, headers_seen|
        provider = Riggs::Providers::OpenAICompatible.new(
          name: "local", options: { base_url: base_url, model: "local-test", auth: "api" }
        )
        provider.complete(messages: [{ role: "user", content: "hi" }])

        assert_includes headers_seen.pop.lines.map(&:strip), "Authorization: Bearer sk-parent-key"
      end
    end
  end

  def test_auth_none_on_cli_adapters_raises_naming_the_provider_and_supported_modes
    cases = [
      [Riggs::Providers::ClaudeCli, "claude_cli"],
      [Riggs::Providers::CodexCli, "codex"],
      [Riggs::Providers::CursorCli, "cursor"]
    ]

    cases.each do |klass, name|
      err = assert_raises(Riggs::Providers::Error) do
        klass.new(name: name, options: { auth: "none" }).auth_mode
      end
      assert_match(/#{name}/, err.message, "the error must name which provider is misconfigured")
      assert_match(/subscription/, err.message, "and list the values that would have worked")
      assert_match(/api/, err.message)
    end
  end

  # Uses the adapter's real child_env and CliRunner.run to spawn a child that
  # reports which variables survived the merge/unset contract.
  def env_seen_by_spawned_child(klass, name:, parent_env:, probe_vars:, options: {})
    with_saved_env(parent_env) do
      provider = klass.new(name: name, options: options)
      child_env = provider.send(:child_env)

      result = Riggs::Providers::CliRunner.run(
        command: "sh",
        args: ["-c", subscription_env_probe_script(probe_vars)],
        env: child_env,
        timeout: 5
      )
      parse_env_probe(result.stdout)
    end
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

  # ANTHROPIC_AUTH_TOKEN outranks ANTHROPIC_API_KEY in Claude Code's own
  # authentication precedence and is the documented variable for a corporate
  # Anthropic-compatible gateway (code.claude.com/docs/en/llm-gateway-connect),
  # so leaving it unscrubbed would let a gateway operator bypass the
  # subscription through a sibling variable -- exactly the failure this phase
  # exists to close, reached one variable over.
  def test_claude_cli_scrubs_the_auth_token_under_subscription
    ENV["ANTHROPIC_AUTH_TOKEN"] = "sk-auth-token-test"
    env = env_handed_to_runner(Riggs::Providers::ClaudeCli, name: "claude_cli")

    assert env.key?("ANTHROPIC_AUTH_TOKEN"), "the key must be present in the hash so it can be unset"
    assert_nil env["ANTHROPIC_AUTH_TOKEN"], "and nil so the child does not receive it"
  ensure
    ENV.delete("ANTHROPIC_AUTH_TOKEN")
  end

  def test_claude_cli_passes_the_auth_token_under_api_mode
    ENV["ANTHROPIC_AUTH_TOKEN"] = "sk-auth-token-test"
    env = env_handed_to_runner(Riggs::Providers::ClaudeCli, name: "claude_cli", options: { auth: "api" })

    assert_equal "sk-auth-token-test", env["ANTHROPIC_AUTH_TOKEN"]
  ensure
    ENV.delete("ANTHROPIC_AUTH_TOKEN")
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

  # Stubbed-runner scrub tests only assert on the hash handed to the runner.
  # If CliRunner stopped honoring nil (e.g. merge(..., env.compact)), every
  # parent API key would still reach the CLI and those tests would keep passing.
  def test_claude_cli_subscription_scrub_reaches_spawned_child
    fake = "sk-parent-should-not-reach-child"
    report = env_seen_by_spawned_child(
      Riggs::Providers::ClaudeCli,
      name: "claude_cli",
      parent_env: {
        "ANTHROPIC_API_KEY" => fake,
        "ANTHROPIC_AUTH_TOKEN" => fake,
        "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-parent-should-reach-child"
      },
      probe_vars: %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN]
    )

    assert_equal "absent", report["ANTHROPIC_API_KEY"],
                 "subscription mode must unset ANTHROPIC_API_KEY in the spawned child"
    assert_equal "absent", report["ANTHROPIC_AUTH_TOKEN"],
                 "subscription mode must unset ANTHROPIC_AUTH_TOKEN in the spawned child"
    assert_equal "present", report["CLAUDE_CODE_OAUTH_TOKEN"],
                 "subscription credentials that are meant to survive must still reach the child"
    # Scope of that last assertion, checked by mutation: adding
    # CLAUDE_CODE_OAUTH_TOKEN to the scrub set DOES fail it, which is the
    # regression worth guarding. Deleting ClaudeCli's explicit forwarding of it
    # does NOT, because the child inherits the parent's copy through
    # ENV.to_h regardless -- so this proves "nothing scrubs it", not "the
    # adapter forwards it". The forwarding is belt-and-braces either way.
  end

  def test_codex_cli_subscription_scrub_reaches_spawned_child
    fake = "sk-parent-should-not-reach-child"
    report = env_seen_by_spawned_child(
      Riggs::Providers::CodexCli,
      name: "codex",
      parent_env: {
        "CODEX_API_KEY" => fake,
        "OPENAI_API_KEY" => fake
      },
      probe_vars: %w[CODEX_API_KEY OPENAI_API_KEY]
    )

    assert_equal "absent", report["CODEX_API_KEY"]
    assert_equal "absent", report["OPENAI_API_KEY"]
  end

  def test_cursor_cli_subscription_scrub_reaches_spawned_child
    fake = "sk-parent-should-not-reach-child"
    report = env_seen_by_spawned_child(
      Riggs::Providers::CursorCli,
      name: "cursor",
      parent_env: { "CURSOR_API_KEY" => fake },
      probe_vars: %w[CURSOR_API_KEY]
    )

    assert_equal "absent", report["CURSOR_API_KEY"]
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
  # Records the base_url the provider was actually built with, which is the
  # only thing that settles where a credential would have been sent. Asserting
  # on the config hash the router assembled would agree with the router's own
  # belief, and that belief is what was wrong.
  def endpoint_probe(seen)
    Class.new(Riggs::Providers::Base) do
      define_method(:complete) do |**|
        seen << options[:base_url]
        { provider: name, content: "ok", usage: {} }
      end
    end
  end

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

  # Pricing is billing truth, and a workflow file travels with a repository.
  # Letting a workflow set pricing let a clone report $0.00 for a run that
  # cost $60.00 -- verified against these exact numbers before the guard.
  # Every other provider field still merges hub <- workflow; this one does not.
  def test_a_workflow_cannot_zero_the_operators_pricing
    router = Riggs::Providers::Router.new(
      hub_providers: { metered: { type: "metered", model: "priced-model",
                                  pricing: { "priced-model" => { input: 1000.0, output: 1000.0 } } } },
      workflow_providers: { metered: { pricing: { "priced-model" => { input: 0.0, output: 0.0 } } } },
      registry: { "metered" => metered_provider }
    )

    result = router.call(chain: ["metered"], messages: [{ role: "user", content: "hello" }])

    assert result[:cost_usd].positive?, "a workflow must not be able to zero the ledger"
  end

  def test_a_workflow_cannot_invent_a_price_the_operator_never_set
    router = Riggs::Providers::Router.new(
      hub_providers: { metered: { type: "metered", model: "unpriced-xyz" } },
      workflow_providers: { metered: { pricing: { "unpriced-xyz" => { input: 5.0, output: 5.0 } } } },
      registry: { "metered" => metered_provider }
    )

    result = router.call(chain: ["metered"], messages: [{ role: "user", content: "hello" }])

    assert_nil result[:cost_usd], "an unpriced model stays unpriced rather than taking a workflow's word"
  end

  # base_url is where the credential GOES, and a workflow file travels with a
  # repository exactly like the project config that was already barred from
  # setting it. Closing only the config tier left the same redirect open one
  # file over: an OpenAICompatible provider sends the operator's key to
  # base_url as a bearer token, so a workflow naming an attacker host collects
  # it. Same treatment as pricing -- hub only, workflow ignored.
  def test_a_workflow_cannot_redirect_the_operators_endpoint
    seen = []
    probe = endpoint_probe(seen)
    Riggs::Providers::Router.new(
      hub_providers: { openai: { base_url: "https://operator.invalid/v1" } },
      workflow_providers: { openai: { base_url: "https://attacker.invalid/v1" } },
      registry: { "openai" => probe }
    ).call(chain: ["openai"], messages: [])

    assert_equal ["https://operator.invalid/v1"], seen, "a workflow must not be able to move the endpoint"
  end

  def test_a_workflow_cannot_supply_an_endpoint_the_operator_never_set
    seen = []
    probe = endpoint_probe(seen)
    Riggs::Providers::Router.new(
      hub_providers: { openai: { model: "gpt-4" } },
      workflow_providers: { openai: { base_url: "https://attacker.invalid/v1" } },
      registry: { "openai" => probe }
    ).call(chain: ["openai"], messages: [])

    assert_equal [nil], seen, "an unset endpoint stays unset rather than taking a workflow's word"
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

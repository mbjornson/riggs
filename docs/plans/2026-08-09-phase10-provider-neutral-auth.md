# Phase 10 — Provider-Neutral Auth — Implementation Plan

**Goal:** Make auth vocabulary provider-owned, validate every dispatched provider before relay, report the resolved mode, and make none actively withhold credentials.

**Architecture:** Base owns class-level resolution through self::AUTH_MODES and self::DEFAULT_AUTH_MODE, so a subclass's vocabulary is read instead of Base's lexical constants. Each provider declares only modes it can honor. Router uses that shared interface before dispatch and in attribution. OpenAI-compatible HTTP skips all key sources under none; CLI adapters retain their existing scrub sets whenever auth is not api.

**Tech Stack:** Ruby 4.0, Minitest, RuboCop, Net::HTTP, TCPServer.

**Spec:** [docs/specs/phase10-provider-neutral-auth.md](../specs/phase10-provider-neutral-auth.md)

## Global Constraints

- Baseline before this plan: **370 runs, 1055 assertions, 0 failures.**
- Every commit runs a pre-commit gate: bundle exec rubocop (clean across 70 files) then bundle exec rake test (0 failures, 0 errors). A commit failing either is rejected. Never use --no-verify.
- Ruby 4.0, Minitest, RuboCop. Layout/LineLength Max is 130.
- Never write a literal control character into a source file.
- Commit messages must end with exactly these two lines:

  ```text
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
  ```

## File Structure

| File | Responsibility |
|---|---|
| lib/riggs/providers/base.rb | Provider-neutral auth constants, resolution, and instance access. |
| lib/riggs/providers/cli.rb | CLI constants; inherits Base resolver. |
| lib/riggs/providers/claude_cli.rb | Existing scrub set for subscription and none. |
| lib/riggs/providers/codex_cli.rb | Existing scrub set for subscription and none. |
| lib/riggs/providers/cursor_cli.rb | Existing scrub set plus argv suppression outside api. |
| lib/riggs/providers/openai_compatible.rb | api/none declaration and Authorization suppression. |
| lib/riggs/providers/anthropic.rb | api-only declaration. |
| lib/riggs/providers/cursor_cloud.rb | api-only declaration. |
| lib/riggs/providers/mock.rb | none-only declaration. |
| lib/riggs/providers/router.rb | Provider-neutral validation and attribution. |
| test/test_providers.rb | Auth vocabulary, validation, and wire-level suppression tests. |
| test/test_graph_engine.rb | workflow_start attribution test. |
| README.md | Provider auth-mode tables. |

---

### Task 1: Provider-owned auth vocabulary

**Files:**
- Modify: lib/riggs/providers/base.rb, lib/riggs/providers/cli.rb, lib/riggs/providers/openai_compatible.rb, lib/riggs/providers/anthropic.rb, lib/riggs/providers/cursor_cloud.rb, lib/riggs/providers/mock.rb
- Test: test/test_providers.rb

**Interfaces:**
- Produces: Riggs::Providers::Base.auth_modes -> Array<String>; Base.default_auth_mode -> String; Base.resolve_auth_mode(value, provider:) -> String, raising Riggs::Providers::Error; Base#auth_mode -> String.
- Produces: Cli::AUTH_MODES = %w[subscription api none].freeze; Cli::DEFAULT_AUTH_MODE = "subscription"; OpenAICompatible = api/none; Anthropic = api; CursorCloud = api; Mock = none.
- Consumes: nothing.

Expected test count: **3 new provider tests; 373 total runs after this task.**

- [ ] **Step 1: Write the failing tests**

Add after test_an_unknown_auth_mode_raises_naming_the_provider_and_the_valid_values in test/test_providers.rb:

```ruby
  def test_provider_classes_declare_their_own_auth_vocabularies_and_defaults
    expectations = {
      Riggs::Providers::Cli => [%w[subscription api none], "subscription"],
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

  def test_non_cli_instances_resolve_their_own_defaults
    assert_equal "api", Riggs::Providers::OpenAICompatible.new(name: "openai", options: {}).auth_mode
    assert_equal "api", Riggs::Providers::Anthropic.new(name: "anthropic", options: {}).auth_mode
    assert_equal "api", Riggs::Providers::CursorCloud.new(name: "cursor_cloud", options: {}).auth_mode
    assert_equal "none", Riggs::Providers::Mock.new(name: "mock", options: {}).auth_mode
  end
```

- [ ] **Step 2: Run the tests and watch them fail**

```bash
bundle exec ruby -Ilib:test:. test/test_providers.rb -n '/provider_classes_declare|subclass_auth_constants|non_cli_instances/'
```

Expected: 3 errors because Base has no auth resolution interface.

- [ ] **Step 3: Implement the shared contract**

In lib/riggs/providers/base.rb, directly below class Base, add:

```ruby
      AUTH_MODES = %w[api].freeze
      DEFAULT_AUTH_MODE = "api"

      def self.auth_modes = self::AUTH_MODES
      def self.default_auth_mode = self::DEFAULT_AUTH_MODE

      def self.resolve_auth_mode(value, provider:)
        mode = value.to_s.strip.downcase
        return default_auth_mode if mode.empty?
        return mode if auth_modes.include?(mode)

        raise Error, "provider '#{provider}': auth mode #{value.inspect} is not " \
                     "supported by #{name} (expected one of: #{auth_modes.join(', ')})"
      end

      def auth_mode = self.class.resolve_auth_mode(options[:auth], provider: name)
```

In lib/riggs/providers/cli.rb, replace the current constants and both auth methods with:

```ruby
      AUTH_MODES = %w[subscription api none].freeze
      DEFAULT_AUTH_MODE = "subscription"
```

Add these declarations directly below each class's existing default constants; Mock's go directly below class Mock < Base:

```ruby
# openai_compatible.rb
      AUTH_MODES = %w[api none].freeze
      DEFAULT_AUTH_MODE = "api"

# anthropic.rb
      AUTH_MODES = %w[api].freeze
      DEFAULT_AUTH_MODE = "api"

# cursor_cloud.rb
      AUTH_MODES = %w[api].freeze
      DEFAULT_AUTH_MODE = "api"

# mock.rb
      AUTH_MODES = %w[none].freeze
      DEFAULT_AUTH_MODE = "none"
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
bundle exec ruby -Ilib:test:. test/test_providers.rb -n '/provider_classes_declare|subclass_auth_constants|non_cli_instances|auth_mode/'
```

Expected: all selected tests pass. The local-only class specifically proves self::AUTH_MODES is required; a bare constant would resolve Base's api-only copy.

- [ ] **Step 5: Full gate**

```bash
bundle exec rubocop && bundle exec rake test
```

Expected: RuboCop clean across 70 files; **373 runs, 0 failures, 0 errors**.

- [ ] **Step 6: Commit**

```bash
git add lib/riggs/providers/base.rb lib/riggs/providers/cli.rb         lib/riggs/providers/openai_compatible.rb lib/riggs/providers/anthropic.rb         lib/riggs/providers/cursor_cloud.rb lib/riggs/providers/mock.rb test/test_providers.rb
git commit -F - <<'MSG'
Move auth vocabulary to provider classes

Base resolves auth through the concrete provider class. Each provider declares
only modes it can honor, including mock's none-only contract. self::AUTH_MODES
prevents a subclass vocabulary from being silently replaced by Base's default.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
MSG
```

---

### Task 2: Validate every dispatched provider and correct attribution

**Files:**
- Modify: lib/riggs/providers/router.rb
- Test: test/test_providers.rb, test/test_graph_engine.rb

**Interfaces:**
- Consumes: Base.resolve_auth_mode(value, provider:) from Task 1.
- Produces: Router#validate_auth_modes!(names), validating each resolved provider class before dispatch; Router#provider_auth_mode(name) -> String | nil, where nil is omitted from Router#auth_modes.

**Existing tests that must change:**

1. test_auth_modes_excludes_the_default_routing_alias_but_keeps_real_providers must expect mock => none rather than api.
2. Replace test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated with the OpenAI-compatible rejection below.
3. Replace test_a_valid_chain_still_dispatches_with_the_auth_guard_in_place with the valid mock-none version below.
4. Replace test_router_auth_modes_marks_an_invalid_value_without_raising_or_dropping_the_rest; it must no longer return the false invalid label.
5. test_workflow_start_records_the_auth_mode_of_every_provider in test/test_graph_engine.rb must expect mock => none.

Expected test count: **3 new provider tests and 5 changed existing tests; 376 total runs after this task.**

- [ ] **Step 1: Write the failing tests and replacements**

Replace test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated with:

```ruby
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
```

Replace test_a_valid_chain_still_dispatches_with_the_auth_guard_in_place with:

```ruby
  def test_a_valid_none_mode_still_dispatches_with_the_auth_guard_in_place
    router = Riggs::Providers::Router.new(
      hub_providers: { "mock" => { "type" => "mock", "auth" => "none" } }
    )

    result = router.call(messages: [{ role: "user", content: "hi" }], chain: ["mock"])

    assert_equal "mock", result[:provider]
  end
```

Replace test_router_auth_modes_marks_an_invalid_value_without_raising_or_dropping_the_rest with, then add the following two tests:

```ruby
  def test_router_auth_modes_rejects_a_configured_invalid_value
    router = Riggs::Providers::Router.new(
      hub_providers: {
        "codex" => { "type" => "codex", "auth" => "api" },
        "claude_cli" => { "type" => "claude_cli", "auth" => "subscribe" }
      }
    )

    err = assert_raises(Riggs::Providers::Error) { router.auth_modes }

    assert_match(/claude_cli/, err.message)
    assert_match(/subscription, api, none/, err.message)
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
```

Change the last assertion in test_auth_modes_excludes_the_default_routing_alias_but_keeps_real_providers:

```ruby
    assert_equal "none", modes["mock"], "a real provider in the same providers: block must still be reported"
```

Change the last assertion in test_workflow_start_records_the_auth_mode_of_every_provider:

```ruby
      assert_equal "none", modes["mock"] || modes[:mock],
                   "mock bills nobody and must be recorded as none"
```

- [ ] **Step 2: Run the tests and watch them fail**

```bash
bundle exec ruby -Ilib:test:. test/test_providers.rb -n '/unsupported_auth_mode_on_openai|valid_none_mode|auth_modes_rejects|anthropic_and_cursor_cloud_reject|omits_a_name|excludes_the_default/' && bundle exec ruby -Ilib:test:. test/test_graph_engine.rb -n /workflow_start_records_the_auth_mode/
```

Expected: non-CLI modes remain ignored, invalid maps return invalid, unknown names report api, and mock reports api.

- [ ] **Step 3: Implement Router resolution**

Replace validate_auth_modes! in lib/riggs/providers/router.rb with:

```ruby
      def validate_auth_modes!(names)
        names.each do |name|
          opts = provider_config(name)
          klass = provider_class_for(name, opts)
          next unless klass

          klass.resolve_auth_mode(opts[:auth], provider: name)
        end
      end
```

Replace provider_auth_mode, including its rescue clause, with:

```ruby
      def provider_auth_mode(name)
        opts = provider_config(name)
        return nil if opts[:relay_chain]

        klass = provider_class_for(name, opts)
        return nil unless klass

        klass.resolve_auth_mode(opts[:auth], provider: name)
      end
```

Keep the existing modes[name] = mode if mode line in auth_modes. It omits unknown provider names without inventing an api fallback.

- [ ] **Step 4: Run the tests and watch them pass**

```bash
bundle exec ruby -Ilib:test:. test/test_providers.rb -n '/unsupported_auth_mode_on_openai|valid_none_mode|auth_modes_rejects|anthropic_and_cursor_cloud_reject|omits_a_name|excludes_the_default/' && bundle exec ruby -Ilib:test:. test/test_graph_engine.rb -n /workflow_start_records_the_auth_mode/
```

Expected: all selected tests pass; Anthropic/Cursor Cloud none fails before their credential checks and no fallback dispatches.

- [ ] **Step 5: Full gate**

```bash
bundle exec rubocop && bundle exec rake test
```

Expected: RuboCop clean across 70 files; **376 runs, 0 failures, 0 errors**.

- [ ] **Step 6: Commit**

```bash
git add lib/riggs/providers/router.rb test/test_providers.rb test/test_graph_engine.rb
git commit -F - <<'MSG'
Validate auth modes for every provider before dispatch

Router asks every resolved provider class whether it honors the declared auth
mode before beginning a relay. Attribution takes the same path, so mock is
recorded as none and unknown names are omitted rather than called API-backed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
MSG
```

---

### Task 3: Withhold credentials under none and document it

**Files:**
- Modify: lib/riggs/providers/openai_compatible.rb, lib/riggs/providers/claude_cli.rb, lib/riggs/providers/codex_cli.rb, lib/riggs/providers/cursor_cli.rb, README.md
- Test: test/test_providers.rb

**Interfaces:**
- Consumes: Base#auth_mode from Task 1.
- Produces: OpenAICompatible#complete reads options[:api_key], OPENAI_API_KEY, and OLLAMA_API_KEY only when auth_mode != "none"; it sends no Authorization header for none.
- Produces: all CLI child_env methods scrub their current key sets when auth_mode != "api"; CursorCli#argv_for(prompt) omits --api-key when auth_mode != "api".

Expected test count: **5 new provider tests; 381 total runs after this task.**

- [ ] **Step 1: Write the failing real-server and adapter tests**

At the top of test/test_providers.rb, directly after require "rbconfig", add:

```ruby
require "socket"
```

Add directly after parse_env_probe:

```ruby
  def with_capturing_openai_server
    server = TCPServer.new("127.0.0.1", 0)
    headers_seen = Queue.new
    thread = Thread.new do
      client = server.accept
      request = +""
      request << client.readpartial(1024) until request.include?("

")
      headers, body = request.split("

", 2)
      content_length = headers[/^Content-Length:s*(d+)/i, 1].to_i
      body ||= ""
      body << client.readpartial(1024) while body.bytesize < content_length

      response_body = JSON.generate(
        "model" => "local-test",
        "choices" => [{ "message" => { "content" => "ok" } }],
        "usage" => {}
      )
      client.write(
        "HTTP/1.1 200 OK
"         "Content-Type: application/json
"         "Content-Length: #{response_body.bytesize}
"         "Connection: close

"         response_body
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
```

Add directly after the helper:

```ruby
  def test_openai_compatible_none_sends_no_authorization_header_to_a_real_local_server
    with_saved_env("OPENAI_API_KEY" => "sk-parent-key") do
      with_capturing_openai_server do |base_url, headers_seen|
        provider = Riggs::Providers::OpenAICompatible.new(
          name: "local", options: { base_url: base_url, model: "local-test", auth: "none" }
        )

        assert_equal "ok", provider.complete(messages: [{ role: "user", content: "hi" }])[:content]
        refute_match(/^Authorization:/i, headers_seen.pop,
                     "auth: none must keep the exported parent key off the wire")
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

  def test_none_uses_the_same_cli_scrub_sets_as_subscription
    cases = [
      [Riggs::Providers::ClaudeCli, "claude_cli",
       { "ANTHROPIC_API_KEY" => "sk-a", "ANTHROPIC_AUTH_TOKEN" => "sk-t" },
       %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN]],
      [Riggs::Providers::CodexCli, "codex",
       { "CODEX_API_KEY" => "sk-c", "OPENAI_API_KEY" => "sk-o" }, %w[CODEX_API_KEY OPENAI_API_KEY]],
      [Riggs::Providers::CursorCli, "cursor", { "CURSOR_API_KEY" => "sk-cursor" }, %w[CURSOR_API_KEY]]
    ]

    cases.each do |klass, name, parent_env, keys|
      with_saved_env(parent_env) do
        subscription = env_handed_to_runner(klass, name: name, options: { auth: "subscription" })
        none = env_handed_to_runner(klass, name: name, options: { auth: "none" })
        keys.each do |key|
          assert_nil subscription[key], "subscription must scrub #{key}"
          assert_nil none[key], "none must scrub #{key} exactly as subscription does"
        end
      end
    end
  end

  def test_claude_code_oauth_token_survives_under_none
    with_saved_env("CLAUDE_CODE_OAUTH_TOKEN" => "oauth-test") do
      env = env_handed_to_runner(Riggs::Providers::ClaudeCli, name: "claude_cli", options: { auth: "none" })

      assert_equal "oauth-test", env["CLAUDE_CODE_OAUTH_TOKEN"]
    end
  end

  def test_cursor_cli_omits_the_api_key_flag_under_none
    captured = nil
    runner = FakeRunner.new(lambda { |args:, **_|
      captured = args
      Riggs::Providers::CliRunner::Result.new(stdout: "ok", stderr: "", status: FakeStatus.new(true))
    })
    Riggs::Providers::CursorCli.new(
      name: "cursor", options: { runner: runner, api_key: "sk-inline", auth: "none" }
    ).complete(messages: [{ role: "user", content: "hi" }])

    refute_includes captured, "--api-key"
    refute_includes captured, "sk-inline"
  end
```

- [ ] **Step 2: Run the tests and watch them fail**

```bash
bundle exec ruby -Ilib:test:. test/test_providers.rb -n '/openai_compatible_(none|api)_|none_uses_the_same_cli|oauth_token_survives_under_none|api_key_flag_under_none/'
```

Expected: none sends Authorization: Bearer sk-parent-key to TCPServer; CLI none takes API paths; Cursor includes --api-key.

- [ ] **Step 3: Implement real credential suppression**

In lib/riggs/providers/openai_compatible.rb, replace the api_key assignment at the start of complete with:

```ruby
        api_key = if auth_mode == "none"
                    nil
                  else
                    options[:api_key] || ENV["OPENAI_API_KEY"] || ENV.fetch("OLLAMA_API_KEY", nil)
                  end
```

Keep this existing request line:

```ruby
        req["authorization"] = "Bearer #{api_key}" if api_key && !api_key.empty?
```

In lib/riggs/providers/claude_cli.rb, replace:

```ruby
        if auth_mode == "subscription"
```

with:

```ruby
        if auth_mode != "api"
```

In lib/riggs/providers/codex_cli.rb, replace the return guard with:

```ruby
        return { "CODEX_API_KEY" => nil, "OPENAI_API_KEY" => nil } if auth_mode != "api"
```

In lib/riggs/providers/cursor_cli.rb, replace both guards with:

```ruby
        return { "CURSOR_API_KEY" => nil } if auth_mode != "api"
```

and:

```ruby
        return args if auth_mode != "api"
```

Do not change scrub membership: Claude keeps ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN, Codex keeps CODEX_API_KEY and OPENAI_API_KEY, Cursor keeps CURSOR_API_KEY, and CLAUDE_CODE_OAUTH_TOKEN remains unscrubbed.

- [ ] **Step 4: Run the tests and watch them pass**

```bash
bundle exec ruby -Ilib:test:. test/test_providers.rb -n '/openai_compatible_(none|api)_|none_uses_the_same_cli|oauth_token_survives_under_none|api_key_flag_under_none/'
```

Expected: all selected tests pass. The none proof is the header received by TCPServer, not the arguments passed to a fake HTTP client; api remains a wire-level control.

- [ ] **Step 5: Update the README provider tables**

Replace the HTTP provider table in README.md with:

```markdown
HTTP providers (direct API):

| Name | Backend | auth: modes |
|------|---------|-------------|
| mock | Deterministic offline | none (default and only mode) |
| claude / anthropic | Anthropic Messages API | api (default and only mode; ANTHROPIC_API_KEY) |
| openai | OpenAI-compatible chat | api (default), none (withholds Authorization) |
| ollama | Local OpenAI-compatible | api (default), none (withholds Authorization) |
```

Replace the CLI introduction and table with:

```markdown
CLI providers (shell out; binaries must be on PATH). They accept auth:
subscription (default), api, or none. Both subscription and none remove API-key
variables from the inherited environment, so an exported key cannot override a
stored CLI login. none is for an intentional non-API credential; api passes the
documented key variables.

| Name | Command | auth: subscription / none | auth: api |
|------|---------|---------------------------|-----------|
| cursor | agent -p … --output-format text | cursor-agent login | CURSOR_API_KEY |
| claude_cli | claude -p … --bare | claude /login, or CLAUDE_CODE_OAUTH_TOKEN | ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN |
| codex | codex exec … | codex login | CODEX_API_KEY or OPENAI_API_KEY |
```

Replace the Cursor Cloud table with:

```markdown
Cursor Cloud Agents (async REST — needs a repo):

| Name | API | auth: modes |
|------|-----|-------------|
| cursor_cloud | POST https://api.cursor.com/v1/agents + poll run | api (default and only mode; CURSOR_API_KEY) |
```

- [ ] **Step 6: Full gate**

```bash
bundle exec rubocop && bundle exec rake test
```

Expected: RuboCop clean across 70 files; **381 runs, 0 failures, 0 errors**.

- [ ] **Step 7: Commit**

```bash
git add lib/riggs/providers/openai_compatible.rb lib/riggs/providers/claude_cli.rb         lib/riggs/providers/codex_cli.rb lib/riggs/providers/cursor_cli.rb         test/test_providers.rb README.md
git commit -F - <<'MSG'
Withhold provider credentials for auth none

OpenAI-compatible providers avoid every API-key source and send no
Authorization header under none, proved with a real local HTTP server while
OPENAI_API_KEY is present in the parent environment.

CLI adapters apply their existing scrubs whenever auth is not api, and Cursor
omits its inline API-key flag. The provider documentation now states each mode
and default.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
MSG
```

## Spec issues found

- R10.1 says Cli::AUTH_MODES keeps its Phase 9 values, but the settled provider table requires none; this plan follows the explicit table: %w[subscription api none].
- R10.1 says the CLI's unrecognized-mode error text is preserved, but its required Base.resolve_auth_mode body changes the current unknown-auth wording; this plan follows the required method body.


# Phase 9 — Subscription Auth for CLI Providers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Riggs workflow step run against a Claude Max/Pro, ChatGPT, or Cursor subscription instead of metered API credits.

**Architecture:** Delete the API-key pre-flight (`Cli#ensure_auth!`) so Riggs stops guessing how third-party CLIs authenticate, and add an explicit `auth: subscription | api` provider option. Under `subscription` — the default — each adapter's `child_env` maps its API-key variables to `nil`, which Ruby's process-spawn contract treats as "unset in the child", so an exported key cannot override the CLI's own stored login. `CliRunner` is untouched: its existing `ENV.to_h.merge(env)` already carries a `nil` through.

**Tech Stack:** Ruby 4.0, Minitest, RuboCop, Thor CLI.

**Spec:** [`docs/specs/phase9-cli-subscription-auth.md`](../specs/phase9-cli-subscription-auth.md)

## Global Constraints

- Every commit runs a pre-commit gate: `bundle exec rubocop` (must be clean across 70 files) then `bundle exec rake test` (must be 0 failures, 0 errors). A commit that fails either is rejected — do not use `--no-verify`.
- Baseline before this plan: **337 runs, 978 assertions, 0 failures.**
- Valid `auth:` values are exactly `"subscription"` and `"api"`. Default is `"subscription"`.
- `subscription` scrubs, per adapter: `ClaudeCli` → `ANTHROPIC_API_KEY`; `CodexCli` → `CODEX_API_KEY` and `OPENAI_API_KEY`; `CursorCli` → `CURSOR_API_KEY`.
- `CLAUDE_CODE_OAUTH_TOKEN` is **never** scrubbed — it is itself a subscription credential.
- Do not modify `lib/riggs/providers/cli_runner.rb`. The `nil`-unsets-variable behavior it already has is the mechanism.
- Do not add columns to any database table. `riggs_provider_calls` has no migration path (`Storage#ensure_columns!` inspects only `riggs_sessions`), so a new column would silently skip existing databases.
- **Never write a literal control character into a source file.** Regexes use `\e`-free notation; if a test needs an ESC byte, build it with `27.chr`. Raw control bytes in source make the file unreadable to tooling and break shell quoting.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
  ```

## File Structure

| File | Responsibility |
|---|---|
| `lib/riggs/providers/cli.rb` | Base for CLI-shelling providers. Gains auth-mode resolution; loses `ensure_auth!` / `require_env!`. |
| `lib/riggs/providers/claude_cli.rb` | Claude Code adapter. Gains scrub. |
| `lib/riggs/providers/codex_cli.rb` | Codex adapter. Gains scrub. |
| `lib/riggs/providers/cursor_cli.rb` | Cursor adapter. Gains scrub + argv change. |
| `lib/riggs/providers/base.rb` | Error classes. Gains `AuthError`. |
| `lib/riggs/providers/cli_runner.rb` | **Unchanged.** Failure classification lives here and gains one branch. |
| `lib/riggs/providers/router.rb` | Gains `#auth_modes` for attribution. |
| `lib/riggs/workflow/graph_engine.rb` | `workflow_start` payload gains `provider_auth_modes`. |
| `test/test_providers.rb` | All provider tests. Two existing tests change (see Task 2). |
| `README.md` | Provider tables document `auth:`. |

---

### Task 1: Auth-mode resolution on `Cli`

Pure addition — no behavior change. Later tasks consume it.

**Files:**
- Modify: `lib/riggs/providers/cli.rb`
- Test: `test/test_providers.rb`

**Interfaces:**
- Produces: `Riggs::Providers::Cli.resolve_auth_mode(value, provider:)` → `String` (`"subscription"` or `"api"`), raises `Riggs::Providers::Error` on an unrecognized value. `Riggs::Providers::Cli#auth_mode` → `String`, reading `options[:auth]`.
- Consumes: nothing.

Note: `Router#provider_config` deep-symbolizes provider options, so the key arrives as `options[:auth]`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_providers.rb`, after the existing `test_codex_cli_with_stubbed_runner`:

```ruby
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
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb -n /auth_mode|unknown_auth/`

Expected: 4 errors, `NoMethodError: undefined method 'auth_mode'`.

- [ ] **Step 3: Implement**

In `lib/riggs/providers/cli.rb`, inside `class Cli < Base`, directly above `def complete`:

```ruby
      AUTH_MODES = %w[subscription api].freeze
      DEFAULT_AUTH_MODE = "subscription"

      # Which account a CLI provider bills. `subscription` scrubs that
      # provider's API-key variables from the child so the CLI falls back to
      # its own stored login; `api` passes them through.
      #
      # An unrecognized value raises rather than defaulting: both defaults
      # spend money, and silently picking one when the operator wrote
      # something else is how a typo becomes a bill against the wrong account.
      def self.resolve_auth_mode(value, provider:)
        mode = value.to_s.strip.downcase
        return DEFAULT_AUTH_MODE if mode.empty?
        return mode if AUTH_MODES.include?(mode)

        raise Error, "provider '#{provider}': unknown auth mode #{value.inspect} " \
                     "(expected one of: #{AUTH_MODES.join(', ')})"
      end

      def auth_mode
        Cli.resolve_auth_mode(options[:auth], provider: name)
      end
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb`

Expected: all pass, no new failures.

- [ ] **Step 5: Full gate**

Run: `bundle exec rubocop && bundle exec rake test`

Expected: RuboCop clean; **341 runs, 0 failures**.

- [ ] **Step 6: Commit**

```bash
git add lib/riggs/providers/cli.rb test/test_providers.rb
git commit -F - <<'MSG'
Add auth-mode resolution to CLI providers

Cli.resolve_auth_mode turns an `auth:` provider option into "subscription" or
"api", defaulting to subscription. An unrecognized value raises instead of
falling back, because both possible fallbacks spend money and one of them
bills the wrong account.

No behavior change yet -- nothing reads auth_mode until the next commit.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
MSG
```

---

### Task 2: Remove the pre-flight and scrub API keys

The core change. The pre-flight removal and the scrubs land together so no commit ships a state where Claude runs without a pre-flight *and* without a scrub.

**Files:**
- Modify: `lib/riggs/providers/cli.rb`, `lib/riggs/providers/claude_cli.rb`, `lib/riggs/providers/codex_cli.rb`, `lib/riggs/providers/cursor_cli.rb`, `README.md`
- Test: `test/test_providers.rb`

**Interfaces:**
- Consumes: `Cli#auth_mode` from Task 1.
- Produces: `child_env` returning hashes whose values may be `nil`, meaning "unset in the child".

**Two existing tests change. Do not skip this — the suite will not go green otherwise.**

1. `test_codex_cli_with_stubbed_runner` (currently around line 131) sets `OPENAI_API_KEY` and asserts `env["CODEX_API_KEY"] == "sk-openai"`. Under the new default that variable is scrubbed. Add `auth: "api"` to its `options:` hash so it keeps testing the pass-through path.
2. `test_cursor_cli_requires_api_key` (currently around line 145) asserts that a missing `CURSOR_API_KEY` raises. That behavior is being deleted. Replace the whole test with `test_cursor_cli_runs_without_an_api_key` below.

- [ ] **Step 1: Write the failing tests**

Replace `test_cursor_cli_requires_api_key` in `test/test_providers.rb` with this, and add the rest after it:

```ruby
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

    assert_nil env["CODEX_API_KEY"]
    assert_nil env["OPENAI_API_KEY"]
  ensure
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("CODEX_API_KEY")
  end

  def test_cursor_cli_scrubs_the_api_key_under_subscription
    ENV["CURSOR_API_KEY"] = "sk-cursor"
    env = env_handed_to_runner(Riggs::Providers::CursorCli, name: "cursor")

    assert_nil env["CURSOR_API_KEY"]
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
```

Then edit the existing `test_codex_cli_with_stubbed_runner` so its provider line reads:

```ruby
    provider = Riggs::Providers::CodexCli.new(name: "codex", options: { runner: runner, auth: "api" })
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb`

Expected: the `runs_without_an_api_key` tests fail with `Riggs::Providers::Error: … requires one of: …`; the scrub tests fail because the key is still present.

- [ ] **Step 3: Remove the pre-flight from `cli.rb`**

In `lib/riggs/providers/cli.rb`: delete the `ensure_auth!` call as the first line of `complete`, and delete both the `def ensure_auth!` stub and the `def require_env!(*keys)` method entirely.

`complete` now begins:

```ruby
      def complete(messages:, system: nil, timeout: 60, tools: nil)
        prompt = build_prompt(messages: messages, system: system)
```

- [ ] **Step 4: Scrub in `claude_cli.rb`**

Replace the whole `ensure_auth!` and `child_env` pair with:

```ruby
      def child_env
        env = {}
        # A subscription credential in its own right -- the documented path for
        # non-interactive use -- so it survives both modes.
        token = ENV.fetch("CLAUDE_CODE_OAUTH_TOKEN", nil)
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token if token && !token.empty?

        if auth_mode == "subscription"
          # nil unsets it in the child. ANTHROPIC_API_KEY otherwise OVERRIDES a
          # Pro/Max subscription (code.claude.com/docs/en/env-vars), so an
          # exported key would silently bill the API account on every step.
          env["ANTHROPIC_API_KEY"] = nil
        else
          key = ENV.fetch("ANTHROPIC_API_KEY", nil)
          env["ANTHROPIC_API_KEY"] = key if key && !key.empty?
        end
        env
      end
```

- [ ] **Step 5: Scrub in `codex_cli.rb`**

Replace the `ensure_auth!` and `child_env` pair with:

```ruby
      def child_env
        # Codex prefers its stored ChatGPT auth over an env key today, so this
        # is belt-and-braces -- but a precedence rule inside someone else's CLI
        # is not something Riggs should depend on staying put.
        return { "CODEX_API_KEY" => nil, "OPENAI_API_KEY" => nil } if auth_mode == "subscription"

        key = ENV.fetch("CODEX_API_KEY", nil)
        key = ENV.fetch("OPENAI_API_KEY", nil) if key.nil? || key.empty?
        key.nil? || key.empty? ? {} : { "CODEX_API_KEY" => key }
      end
```

- [ ] **Step 6: Scrub in `cursor_cli.rb`**

Replace the `ensure_auth!` and `child_env` pair with:

```ruby
      def child_env
        return { "CURSOR_API_KEY" => nil } if auth_mode == "subscription"

        key = ENV.fetch("CURSOR_API_KEY", nil)
        key.nil? || key.empty? ? {} : { "CURSOR_API_KEY" => key }
      end
```

and replace `argv_for` with:

```ruby
      def argv_for(prompt)
        args = ["-p", prompt, "--output-format", "text"]
        model = options[:model]
        args += ["--model", model.to_s] if model && !model.to_s.empty?
        # An argv flag would route the key past the env scrub entirely.
        return args if auth_mode == "subscription"

        api_key = options[:api_key]
        args = ["--api-key", api_key.to_s] + args if api_key && !api_key.to_s.empty?
        args
      end
```

- [ ] **Step 7: Run the tests and watch them pass**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb`

Expected: all pass.

- [ ] **Step 8: Update the README**

In `README.md`, replace the CLI providers table (currently lines 108-113, the one headed `CLI providers (shell out; binaries must be on PATH)`) with:

```markdown
CLI providers (shell out; binaries must be on `PATH`). These run against your
**subscription** by default — Riggs removes the API-key variables from the
child process so the CLI uses its own stored login (`codex login`,
`claude /login`, `cursor-agent login`). Set `auth: api` on the provider to bill
metered API credits instead.

| Name | Command | `auth: subscription` (default) | `auth: api` |
|------|---------|-------------------------------|-------------|
| `cursor` | `agent -p … --output-format text` | `cursor-agent login` | `CURSOR_API_KEY` |
| `claude_cli` | `claude -p … --bare` | `claude /login`, or `CLAUDE_CODE_OAUTH_TOKEN` | `ANTHROPIC_API_KEY` |
| `codex` | `codex exec …` | `codex login` | `CODEX_API_KEY` or `OPENAI_API_KEY` |

```yaml
# .agent_hubrc
providers:
  codex:      { type: codex }                  # uses your ChatGPT subscription
  claude_api: { type: claude_cli, auth: api }  # bills ANTHROPIC_API_KEY
```

`ANTHROPIC_API_KEY` overrides a Claude Pro/Max subscription when Claude Code
sees it, so `auth: subscription` unsets it for the child rather than trusting
it to be absent.
```

- [ ] **Step 9: Full gate**

Run: `bundle exec rubocop && bundle exec rake test`

Expected: RuboCop clean; **349 runs, 0 failures** (341 from Task 1, +9 new, −1 replaced).

- [ ] **Step 10: Commit**

```bash
git add lib/riggs/providers/cli.rb lib/riggs/providers/claude_cli.rb \
        lib/riggs/providers/codex_cli.rb lib/riggs/providers/cursor_cli.rb \
        test/test_providers.rb README.md
git commit -F - <<'MSG'
Run CLI providers on subscription auth by default

Cli#ensure_auth! refused to spawn a CLI unless an API-key variable was set, so
a codex logged in via ChatGPT -- working fine from a shell -- was unusable
from a workflow step. The check is deleted rather than taught about
subscription auth: Riggs cannot know how a third-party CLI authenticates, and
that enumeration was already incomplete when written.

Relaxing it alone would have been unsafe. ANTHROPIC_API_KEY overrides a
Pro/Max subscription, and CliRunner builds the child env as ENV.to_h.merge, so
an exported key would silently bill the API account on every step. Under
auth: subscription each adapter now maps its API-key variables to nil, which
unsets them in the child. CLAUDE_CODE_OAUTH_TOKEN survives -- it is itself a
subscription credential.

CursorCli also stops passing --api-key on argv under subscription, since that
channel bypasses the env scrub.

Two existing tests changed: the codex stubbed-runner test now declares
auth: api to keep testing pass-through, and the test asserting a missing
CURSOR_API_KEY raises is replaced by one asserting it runs.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
MSG
```

---

### Task 3: `AuthError`

**Files:**
- Modify: `lib/riggs/providers/base.rb`, `lib/riggs/providers/cli_runner.rb`
- Test: `test/test_providers.rb`

**Interfaces:**
- Produces: `Riggs::Providers::AuthError < Riggs::Providers::Error`.
- Consumes: nothing from Tasks 1-2.

`raise_for_failure!` is `private_class_method`, so test it through `CliRunner.run` against a real command that exits non-zero with the text on stderr.

- [ ] **Step 1: Write the failing tests**

```ruby
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
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb -n /auth_error|not_logged_in|rate_limited|ordinary_failure/`

Expected: `NameError: uninitialized constant Riggs::Providers::AuthError`.

- [ ] **Step 3: Add the class**

In `lib/riggs/providers/base.rb`, below `class TimeoutError < Error; end`:

```ruby
    # The CLI ran but is not authenticated. A subclass of Error on purpose:
    # Router relays to the next provider on Error, and a provider that is not
    # logged in should fail over exactly like any other failure.
    class AuthError < Error; end
```

- [ ] **Step 4: Classify in `cli_runner.rb`**

Add the constant beside the module's other definitions, above `def run`:

```ruby
      AUTH_FAILURE = /not logged in|unauthorized|401|authentication|please (run )?login|no credentials/i
```

Then in `raise_for_failure!`, add the auth branch **after** the existing rate-limit branch and before the final `raise Error`:

```ruby
        if combined.match?(AUTH_FAILURE)
          raise AuthError, "CLI not authenticated: #{argv.first}: #{result.stderr[0, 200]}"
        end
```

Leave the rate-limit branch exactly as it is. Ordering is cosmetic — Router treats all three identically — so the established check keeps its place.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb`

Expected: all pass.

- [ ] **Step 6: Full gate**

Run: `bundle exec rubocop && bundle exec rake test`

Expected: RuboCop clean; **354 runs, 0 failures**.

- [ ] **Step 7: Commit**

```bash
git add lib/riggs/providers/base.rb lib/riggs/providers/cli_runner.rb test/test_providers.rb
git commit -F - <<'MSG'
Classify CLI auth failures as AuthError

With the API-key pre-flight gone, "not logged in" is the error an operator
will hit most often, and it arrived indistinguishable from a crash. AuthError
subclasses Error so Router's single rescue clause still relays to the next
provider in the chain -- the class exists to label the failure, not to change
control flow.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
MSG
```

---

### Task 4: Attribution — `provider_auth_modes` on `workflow_start`

**Files:**
- Modify: `lib/riggs/providers/router.rb`, `lib/riggs/workflow/graph_engine.rb`
- Test: `test/test_providers.rb`, `test/test_graph_engine.rb`

**Interfaces:**
- Consumes: `Cli.resolve_auth_mode(value, provider:)` from Task 1.
- Produces: `Router#auth_modes` → `Hash[String, String]`, every configured provider name to `"subscription"` or `"api"`.

Auth mode is a property of provider *configuration*, not of a call, so it is recorded once per run. Joined against `riggs_provider_calls.provider` — already recorded per call — it recovers the billing account for every step, and stays accurate for historical runs if the config later changes.

- [ ] **Step 1: Write the failing tests**

In `test/test_providers.rb`:

```ruby
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
```

In `test/test_graph_engine.rb`, add to the class:

```ruby
  # Which account a step billed must be recoverable from the audit trail alone,
  # without reading whatever the config happens to say later.
  def test_workflow_start_records_the_auth_mode_of_every_provider
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
        gate_handler: ->(*) { :approved }
      )
      engine.execute(StringIO.new, input: { ticket: "Password reset request" })

      start = engine.audit_log.find { |e| e[:event_type] == "workflow_start" }
      refute_nil start, "expected a workflow_start event"
      modes = start[:payload][:provider_auth_modes] || start[:payload]["provider_auth_modes"]

      refute_nil modes, "workflow_start must carry provider_auth_modes"
      assert_equal "api", modes["mock"] || modes[:mock],
                   "a non-CLI provider bills its API key by definition"
    end
  end
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb -n /auth_modes/ && bundle exec ruby -Ilib:test:. test/test_graph_engine.rb -n /auth_mode/`

Expected: `NoMethodError: undefined method 'auth_modes'`, then a nil `provider_auth_modes`.

- [ ] **Step 3: Add `Router#auth_modes`**

In `lib/riggs/providers/router.rb`, add `require_relative "cli"` beside the other provider requires, then add this public method directly below `def chain_for`:

```ruby
      # Every configured provider mapped to the account it will bill. Recorded
      # once per run rather than per call: auth mode is a property of provider
      # configuration, and riggs_provider_calls already records which provider
      # answered each call, so the two together recover the billing account for
      # every step -- without a schema change, which riggs_provider_calls has no
      # migration path for.
      def auth_modes
        names = (@hub_providers.keys + @workflow_providers.keys).map(&:to_s).uniq.sort
        names.each_with_object({}) do |name, modes|
          opts = provider_config(name)
          klass = @registry[name] || @registry[opts[:type]&.to_s || name]
          modes[name] = if klass && klass <= Cli
                          Cli.resolve_auth_mode(opts[:auth], provider: name)
                        else
                          "api"
                        end
        end
      end
```

- [ ] **Step 4: Record it on `workflow_start`**

In `lib/riggs/workflow/graph_engine.rb`, replace the `log_event("workflow_start", …)` line (currently line 75) with:

```ruby
        log_event("workflow_start", { workflow: @workflow[:name], user: @user_identity[:id],
                                      provider_auth_modes: @router.auth_modes })
```

- [ ] **Step 5: Run the tests and watch them pass**

Run: `bundle exec ruby -Ilib:test:. test/test_providers.rb && bundle exec ruby -Ilib:test:. test/test_graph_engine.rb`

Expected: all pass.

- [ ] **Step 6: Full gate**

Run: `bundle exec rubocop && bundle exec rake test`

Expected: RuboCop clean; **358 runs, 0 failures**.

- [ ] **Step 7: Commit**

```bash
git add lib/riggs/providers/router.rb lib/riggs/workflow/graph_engine.rb \
        test/test_providers.rb test/test_graph_engine.rb
git commit -F - <<'MSG'
Record provider auth modes on workflow_start

A completed run can now answer which account each step billed. Auth mode is a
property of provider configuration rather than of a call, so it is recorded
once per run and joined against riggs_provider_calls.provider, which already
records which provider answered each call.

Recorded in the audit payload rather than as a column: riggs_provider_calls
has no migration path -- Storage#ensure_columns! inspects only riggs_sessions
-- so a new column would apply to fresh databases and silently skip existing
ones.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
MSG
```

---

## Manual verification (not automated)

CI has no subscription, so the definition of done is checked by hand on a
machine that does. Run after Task 4:

```bash
codex login status          # expect: Logged in using ChatGPT
env | grep -E 'CODEX_API_KEY|OPENAI_API_KEY'   # expect: no output

cd /Users/matt/Projects/riggs
ruby -Ilib -e '
require "riggs"
p_ = Riggs::Providers::CodexCli.new(name: "codex", options: {})
puts p_.complete(messages: [{ role: "user", content: "Reply with exactly: OK" }], timeout: 90)[:content]
'
```

Expected: `OK`. Before this plan, the same command raises
`Riggs::Providers::Error: codex requires one of: CODEX_API_KEY, OPENAI_API_KEY`.

Then confirm the Claude scrub holds:

```bash
ANTHROPIC_API_KEY=sk-invalid-probe ruby -Ilib -e '
require "riggs"
captured = nil
runner = Object.new
runner.define_singleton_method(:run) { |env:, **_| captured = env; raise "stop" }
begin
  Riggs::Providers::ClaudeCli.new(name: "claude_cli", options: { runner: runner })
    .complete(messages: [{ role: "user", content: "hi" }])
rescue StandardError
  nil
end
puts "ANTHROPIC_API_KEY handed to child: #{captured["ANTHROPIC_API_KEY"].inspect}"
'
```

Expected: `nil`.

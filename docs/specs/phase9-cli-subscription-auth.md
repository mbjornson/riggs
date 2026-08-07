# Phase 9 Spec — Subscription Auth for CLI Providers

Status: approved, not yet implemented
Gaps closed: none from the Pi comparison — found while brainstorming `gaps.md` #6
Date: 2026-08-07

## Motivation

Riggs ships four providers that shell out to a locally installed agent CLI:
`claude_cli`, `codex_cli`, `cursor_cli`, and `cursor_cloud`. Those CLIs are the
only way to run Riggs workflows against a Claude Max/Pro, ChatGPT, or Cursor
**subscription** rather than metered API credits.

None of them work on subscription auth today. `Cli#ensure_auth!` refuses to run
unless an API-key environment variable is present:

| Adapter | Requires |
|---|---|
| `ClaudeCli` | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` |
| `CursorCli` | `CURSOR_API_KEY` |
| `CodexCli` | `CODEX_API_KEY` or `OPENAI_API_KEY` |

Demonstrated on the author's machine, where `codex` is logged in via ChatGPT
(`~/.codex/auth.json` has `auth_mode: chatgpt`, OAuth tokens, and no API key;
`codex login status` reports "Logged in using ChatGPT"):

```
riggs CodexCli => Riggs::Providers::Error: codex requires one of: CODEX_API_KEY, OPENAI_API_KEY
```

The same `codex exec` invocation succeeds when run directly. Riggs is refusing
to use a CLI that is authenticated and working.

Relaxing the check alone is not sufficient, because the two CLIs resolve
precedence in **opposite** directions:

- **codex** — stored ChatGPT auth beats an environment key. Verified: exporting
  `OPENAI_API_KEY=sk-invalid-probe-value` and running `codex exec` still
  succeeded.
- **claude** — the environment key beats the subscription. Per
  [code.claude.com/docs/en/env-vars](https://code.claude.com/docs/en/env-vars):
  "`ANTHROPIC_API_KEY` … when set, overrides your Claude Pro, Max, Team, or
  Enterprise subscription … to use your subscription instead, you must unset
  this variable."

`CliRunner#run` builds the child environment as `ENV.to_h.merge(env)`, so the
child inherits everything the parent has. If `ANTHROPIC_API_KEY` is exported —
an ordinary thing to have in a shell profile — every `claude_cli` step would
silently bill the API account instead of the subscription. Silent, per step,
and costing real money.

## Non-goals

- **Parsing usage out of CLI output.** CLI providers return `usage: {}`, so
  subscription steps stay unmeasured in `workflow:inspect`. `codex exec` does
  report usage (`tokens used 16,566` on stderr, and structurally under
  `--json`), so this is achievable, but the output shape differs per provider
  and it is a separate piece of work.
- **Changing `CliRunner`.** The scrub needs nothing from it. See R9.3.
- **Auth for the non-CLI providers.** `anthropic` and `openai_compatible` take
  an API key by definition; `auth:` does not apply to them.
- **A credential store.** Riggs never reads, writes, or holds subscription
  credentials. Each CLI owns its own login state.
- **Interactive login.** Riggs does not run `codex login` or `claude /login` on
  the user's behalf. It reports that the CLI is not authenticated and stops.

## Decisions

Recorded with their reasoning so they do not get relitigated.

1. **No pre-flight auth check at all.** `ensure_auth!` is deleted rather than
   taught about subscription auth. Riggs cannot know how a third-party CLI
   authenticates, and the enumeration it currently carries was already
   incomplete on the day it was written. This is the same failure mode Phase 8
   hit four times with hand-written `rescue` class lists for Psych: each new
   escape was a state nobody had enumerated, and the fix that finally held was
   to stop enumerating. The CLI is the only component that knows its own auth
   state; let it answer.
2. **`subscription` is the default.** The two candidate defaults fail
   differently: defaulting to `api` silently spends money against the wrong
   account, while defaulting to `subscription` produces a loud "not logged in"
   error from a CLI that is not authenticated. Prefer the loud failure.
3. **Scrubbing is a positive action, not a prediction.** Removing a variable
   from the child is something Riggs controls and can test. Relying on
   "codex prefers stored auth" is a prediction about someone else's precedence
   rule that could change between CLI versions. Codex is scrubbed too, even
   though it does not currently need to be.
4. **Attribution goes in the audit payload, not a new column.**
   `riggs_provider_calls` has no migration path — `Storage#ensure_columns!`
   inspects only `riggs_sessions`, and the other tables are
   `CREATE TABLE IF NOT EXISTS`, which does nothing to a table that already
   exists. A new column would apply to fresh databases and silently skip
   existing ones. The audit payload is JSON and needs no schema change. Fixing
   the migration gap is worth doing on its own and should not be smuggled in
   here as a prerequisite.

## R9.1 The `auth:` provider option

A CLI-type provider entry in `.agent_hubrc` accepts `auth:`, whose value is
`subscription` (default) or `api`:

```yaml
providers:
  codex:      { type: codex }                 # subscription
  claude_cli: { type: claude_cli }            # subscription
  claude_api: { type: claude_cli, auth: api } # metered API billing
```

`Cli#auth_mode` reads `options[:auth]`, downcases it, and returns
`"subscription"` for `nil` or an empty value. Any value other than
`"subscription"` or `"api"` raises `Riggs::Providers::Error` naming the
provider and the two valid values — a typo like `auth: subscribe` must not
silently fall back to a default that spends money.

`auth:` on a non-CLI provider is ignored, not an error: `anthropic` and
`openai_compatible` have no CLI to defer to.

## R9.2 `ensure_auth!` is removed

`Cli#ensure_auth!` and `Cli#require_env!` are deleted, along with the three
adapter overrides of `ensure_auth!`. `Cli#complete` no longer calls it.

An unauthenticated CLI now fails at `raise_for_failure!` with the CLI's own
stderr, which is the message that actually describes the problem.

## R9.3 Per-adapter scrub sets

`child_env` returns a hash whose values are `nil` for variables to remove.
`CliRunner` needs no change: `ENV.to_h.merge(env)` carries a `nil` through, and
Ruby's process-spawn contract treats a `nil` value as "unset this variable in
the child". Verified:

```
scrub via nil  -> child sees: [UNSET]
no scrub       -> child sees: [sk-parent-value]
```

Under `auth: subscription`:

| Adapter | Set to `nil` | Left alone |
|---|---|---|
| `ClaudeCli` | `ANTHROPIC_API_KEY` | `CLAUDE_CODE_OAUTH_TOKEN` |
| `CodexCli` | `CODEX_API_KEY`, `OPENAI_API_KEY` | — |
| `CursorCli` | `CURSOR_API_KEY` | — |

`CLAUDE_CODE_OAUTH_TOKEN` is kept because it *is* a subscription credential —
the documented path for non-interactive use, issued by `claude setup-token`.

Under `auth: api`, `child_env` behaves as it does today: it passes the API-key
variables through, and `CodexCli` keeps its existing translation of
`OPENAI_API_KEY` into `CODEX_API_KEY`.

`CursorCli#argv_for` prepends `--api-key` when `options[:api_key]` is set. Under
`auth: subscription` that flag is omitted, since passing a key on the command
line defeats the scrub.

`cursor_cloud` is a REST provider rather than a CLI subclass and is out of scope
for the scrub; it is listed in the Motivation only because it also targets
Cursor.

## R9.4 `AuthError`

`Riggs::Providers::AuthError < Riggs::Providers::Error`, raised from
`raise_for_failure!` when the combined stdout/stderr matches an
authentication-failure pattern:

```ruby
/not logged in|unauthorized|401|authentication|please (run )?login|no credentials/i
```

The existing rate-limit check stays first and is not modified. Ordering is
cosmetic here — `Router` rescues `RateLimitError, TimeoutError, Error` in a
single clause (`router.rb:75`) and relays to the next provider for all three —
so the classification is a label, not control flow. Leaving the established
check ahead of the new one keeps the change minimal.

Subclassing `Error` rather than introducing a sibling is what preserves that
relay behavior: an auth failure should fall through to the next provider in the
chain exactly like any other failure. The distinct class exists so an operator
reading a failed run sees "this provider was not logged in" rather than "this
provider failed".

## R9.5 Attribution

Provider calls are recorded as rows in `riggs_provider_calls`, not as audit
events — `GraphEngine#record_provider_call` is the single writer, and the audit
stream (`workflow_start`, `step_executed`, `tool_call`, …) is separate. There is
no per-call event payload to extend, and adding a column is ruled out by
Decision 4.

Auth mode is a property of provider *configuration*, not of an individual call,
so it is recorded once per run. The `workflow_start` audit payload gains
`provider_auth_modes` — a map of every configured provider name to the mode it
resolved to:

```json
{ "workflow": "build_feature", "user": "matt",
  "provider_auth_modes": { "codex": "subscription", "claude_api": "api" } }
```

`riggs_provider_calls.provider` already records which provider answered each
call, so joining that name against this map recovers the billing account for
every step of the run — and it stays accurate for historical runs even if the
config changes later, which deriving it from current config at read time would
not.

Non-CLI providers report `"api"`.

No schema change, and one additional event field per run rather than per call.

## R9.6 Tests

`CliRunner` is injectable through `options[:runner]`, so every test below runs
without spawning a process. A fake runner records the `command`, `args`, and
`env` it was handed and returns a canned `Result`.

Scrub behavior, per adapter:

- under `auth: subscription`, the recorded `env` maps that adapter's API-key
  variables to `nil`
- under `auth: api`, the same variables are present with their values
- `ClaudeCli` under `subscription` leaves `CLAUDE_CODE_OAUTH_TOKEN` intact
- `CursorCli` under `subscription` omits `--api-key` from argv even when
  `options[:api_key]` is set; under `api` it includes it

Auth mode:

- `auth_mode` defaults to `"subscription"` when the key is absent, `nil`, or an
  empty string
- an unrecognized value raises `Riggs::Providers::Error` naming the provider

Removal of the pre-flight:

- a provider with no API-key variables in the environment reaches the runner
  rather than raising — the regression this phase exists to fix, and it must
  fail before the change

Errors:

- a runner whose result is a non-zero status with "Not logged in" on stderr
  raises `AuthError`, and the message contains the CLI's own text
- a rate-limited result still raises `RateLimitError`, not `AuthError`
- `Router` falls through to the next provider in the chain when the first
  raises `AuthError`

Attribution:

- a completed run emits `workflow_start` carrying `provider_auth_modes`, with
  an entry for every configured provider
- a provider declared `auth: api` reports `"api"` there, and one left at the
  default reports `"subscription"`
- a non-CLI provider (`anthropic`, `openai_compatible`) reports `"api"`

End-to-end, excluded from the default suite: an opt-in test guarded by an
environment variable that runs a real `codex exec` and asserts it succeeds with
no API-key variables set. CI has no subscription, so this cannot be a default
gate.

## Definition of done

On a machine where `codex login status` reports a ChatGPT login and no
`CODEX_API_KEY` or `OPENAI_API_KEY` is set, a workflow step declaring
`provider: codex` runs to completion — the case that raises
`Riggs::Providers::Error: codex requires one of: CODEX_API_KEY, OPENAI_API_KEY`
today.

With `ANTHROPIC_API_KEY` exported, a step declaring `provider: claude_cli`
still uses the Claude subscription, because the variable does not reach the
child process.

That run's `workflow_start` audit event carries
`provider_auth_modes: { "codex": "subscription", "claude_cli": "subscription" }`,
so the account each step billed is recoverable from the audit trail alone.

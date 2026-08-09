# Phase 10 Spec — Provider-Neutral Auth

Status: approved, not yet implemented
Supersedes: Phase 9 R9.1's "`auth:` on a non-CLI provider is ignored, not validated"
Replaces: an earlier, withdrawn Phase 10 spec (`8be068b`, removed) that bundled
this with Cursor execution modes, Ollama defaults, `:cloud` policy, and
zero-cost reporting. A codex review found those to be one coupled change whose
audit and cost halves, if shipped before enforcement existed, would have
produced exactly the false records this line of work exists to remove. This
spec is the foundation of that split; see "What comes after this".
Date: 2026-08-09

## Motivation

Phase 9 gave CLI providers an `auth:` option and made the resolved mode part of
the `workflow_start` audit payload, so an operator can recover which account
paid for each step. Two things are wrong with it.

### The auth vocabulary is owned by the wrong class

`AUTH_MODES` and `DEFAULT_AUTH_MODE` live on `Cli`, so the vocabulary is
CLI-shaped: `subscription | api`, defaulting to `subscription`. Every non-CLI
provider is handled by R9.1's blanket rule that `auth:` there is ignored, and
`Router#provider_auth_mode` hardcodes `"api"` for anything that is not a `Cli`.

That is wrong in both directions.

It is wrong for a local model. `ollama` resolves to `OpenAICompatible`, which
sets an `Authorization` header only when a key is present — so local inference
already works with no credential at all, and the audit records it as billing an
API account:

```
auth_modes = {"codex" => "subscription", "ollama" => "api"}
```

A model running on `127.0.0.1` with no credentials bills nobody.

It is also wrong for providers that genuinely cannot honor anything else.
`Anthropic#complete` raises `"ANTHROPIC_API_KEY not set"` when no key is present
and always sends `x-api-key` (`anthropic.rb:19`). `CursorCloud` requires
`CURSOR_API_KEY`. Any scheme that lets an operator declare something else on
those providers records a claim the code cannot deliver.

### Riggs ships a credential it was never asked to send

`OpenAICompatible` reads `options[:api_key] || ENV["OPENAI_API_KEY"] ||
ENV["OLLAMA_API_KEY"]` and sets a Bearer header when any is present. Verified
against a local HTTP server that logged what it actually received:

```
base_url = localhost (a local ollama endpoint)
Authorization header the LOCAL server received: Bearer <the OPENAI_API_KEY from my shell>
```

That is the Phase 9 failure one layer up: a key exported for one purpose riding
along to a different destination, silently. On localhost the harm is small, but
the same code path sends it wherever `base_url` points.

## Non-goals

Each of these was in the withdrawn spec and is deferred deliberately. The order
matters and is explained in "What comes after this".

- **Cursor execution modes (`--mode plan|ask`).** Deferred: the option name
  collides with `CursorCloud`'s existing `options[:mode]` (`cursor_cloud.rb:65`),
  and the "read-only step" claim does not hold while `ToolLoop` executes
  `TOOL:` responses through MCP on the model's say-so (`tool_loop.rb:43,99`).
  Both need resolving before the feature is worth specifying.
- **Ollama alias and default resolution.** `Router#build` applies the localhost
  base URL and `OLLAMA_MODEL` only when the provider *name* is literally
  `"ollama"`, not when `type: ollama` (`router.rb:160-162`). Any spec that
  reasons about Ollama models must fix that first or its examples will be wrong.
- **The `:cloud` contradiction guard.** Depends on the above: `OLLAMA_MODEL` is
  injected inside `build`, after validation runs, so a model-based guard placed
  in validation is bypassable today.
- **`cost_usd = 0.0` for free providers.** Depends on this spec's enforcement
  existing first, and additionally requires redefining what `priced_calls`
  counts: `Storage` treats any non-NULL cost as priced, so a zero would report
  "1 of 1 priced, 0 of 1 measured" in both `workflow:inspect` and the web
  session view. That is a coherent change, but it is a reporting-semantics
  change with its own UI, docs, and tests.
- **Changing what `provider_auth_modes` costs or how it is stored.** Unchanged
  from Phase 9 R9.5: one field on `workflow_start`, no schema change.

## Decisions

1. **A provider class declares its own auth vocabulary.** `Base` gains
   `AUTH_MODES` and `DEFAULT_AUTH_MODE`, and each provider overrides them. This
   is Phase 9 Decision 1 applied correctly: Riggs should not centrally enumerate
   how every provider authenticates, it should ask the thing that knows. The
   previous design put one global list on `Cli` and then special-cased
   everything else at the call site, which is the same shape as the pre-flight
   Phase 9 deleted.
2. **A mode a provider cannot honor is a configuration error, not a label.**
   `auth: none` on `Anthropic` raises, because `Anthropic` always sends a key
   and no declaration changes that. Accepting the value and recording `"none"`
   would put a false billing record in the audit trail, which is the failure
   this work exists to prevent.
3. **Defaults are per provider, and chosen to preserve today's reported
   behavior.** Non-CLI providers default to `api`, which is what
   `provider_auth_mode` hardcodes for them today, so no existing configuration
   changes meaning. A single global default cannot do this: `Cli`'s default is
   `subscription`, and reusing it for non-CLI providers would silently
   reclassify every one of them from `api` to `subscription` while they
   continued sending API keys.
4. **`none` must suppress, not annotate.** Same principle as Phase 9
   Decision 3: scrubbing is a positive action Riggs controls and can test. A
   provider may only allow `none` if it actually withholds the credential.
5. **`mock` bills nobody, and says so.** Its only mode is `none`. A test fixture
   that reports billing an API account is the same class of false record as the
   local model, and it is cheap to fix now.
6. **Validation stays where Phase 9 put it.** `Router#validate_auth_modes!`,
   before the dispatch loop and outside the relay rescue, so a bad value fails
   the run closed instead of relaying to a provider that costs money.

## R10.1 Auth vocabulary moves to the provider class

`Riggs::Providers::Base` gains:

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

`self::AUTH_MODES` rather than a bare `AUTH_MODES` is load-bearing: a bare
constant resolves lexically to `Base`'s copy even when called on a subclass.

Per-provider declarations:

| Provider | `AUTH_MODES` | `DEFAULT_AUTH_MODE` | Why |
|---|---|---|---|
| `Cli` (and its three adapters) | `subscription api none` | `subscription` | Phase 9 R9.1, unchanged |
| `OpenAICompatible` | `api none` | `api` | Sends a key only if one exists, so it can withhold one |
| `Anthropic` | `api` | `api` | Raises without a key and always sends `x-api-key` |
| `CursorCloud` | `api` | `api` | Requires `CURSOR_API_KEY` |
| `Mock` | `none` | `none` | Bills nobody |

`Cli::AUTH_MODES` and `Cli::DEFAULT_AUTH_MODE` keep their names and their
location on `Cli`, and `Cli.resolve_auth_mode(value, provider:)` keeps its call
signature, so every Phase 9 call site compiles unchanged. Two things do change,
and both are intended:

- `Cli::AUTH_MODES` gains `none`, per the table above. Phase 9's value was
  `%w[subscription api]`.
- The error text for an unrecognized value changes. Phase 9 raised
  `"provider 'x': unknown auth mode "y" (expected one of: subscription, api)"`.
  The `Base` implementation raises `"provider 'x': auth mode "y" is not
  supported by Riggs::Providers::Anthropic (expected one of: api)"` — it has to
  name the class, because the whole point is that the supported set now differs
  per provider and "expected one of" alone no longer tells the operator which
  provider's rules they hit.

Phase 9's `test_an_unknown_auth_mode_raises_naming_the_provider_and_the_valid_values`
asserts on the provider name and the valid values, not the exact sentence, so it
survives. Confirmed by running its three `assert_match` patterns (`/codex/`,
`/subscription/`, `/api/`) against the new message: all three still match.

## R10.2 Validation covers every dispatched provider

`Router#validate_auth_modes!` drops its `next unless klass && klass <= Cli`
guard and calls `klass.resolve_auth_mode(opts[:auth], provider: name)` for every
name in the chain that resolves to a class. A name that resolves to no class is
skipped here and raises from `build` with its existing "Unknown provider"
message.

This supersedes Phase 9 R9.1. That rule ignored `auth:` on non-CLI providers on
the grounds that there was no CLI to defer to and a stray key was harmless.
Once `none` is meaningful there, that stops being true: `auth: nonw` would
otherwise fall through to sending the API key — the same money-typo trap Phase 9
Decision 2 exists to prevent.

`Router#provider_auth_mode` resolves through the same class method. For a name
that resolves to no class it returns `nil` and is omitted from the map, rather
than reporting `"api"` for something that can never be dispatched.

## R10.3 `none` withholds the credential

`OpenAICompatible#complete` sends no `Authorization` header when
`auth_mode == "none"`, and does not read `options[:api_key]`,
`OPENAI_API_KEY`, or `OLLAMA_API_KEY` at all in that case.

The three `Cli` adapters scrub whenever the mode is not `api`, rather than only
when it is `subscription` — so `none` gets the same treatment `subscription`
already has. Concretely, each adapter's `child_env` branch condition changes
from `auth_mode == "subscription"` to `auth_mode != "api"`, and
`CursorCli#argv_for` omits `--api-key` under the same condition. Phase 9's
scrub sets are otherwise unchanged, and `CLAUDE_CODE_OAUTH_TOKEN` is still never
scrubbed.

## R10.4 Attribution

`provider_auth_modes` on `workflow_start` reports whatever each provider
resolved to, now including `"none"`. No schema change and no new field —
Phase 9 R9.5's payload shape is unchanged.

`cost_usd` is **not** changed by this phase. A call on a `none` provider reports
its cost exactly as it does today, which for a model with no pricing entry is
`nil` — "unknown", not "free". Making it `0.0` is deferred, with its reasoning,
to the follow-on phase.

## R10.5 Tests

- each provider class reports its own `auth_modes` and `default_auth_mode`, and
  a subclass's values are read rather than `Base`'s (the `self::` trap)
- omitting `auth:` yields `api` on every non-CLI provider and `subscription` on
  a CLI provider
- `auth: none` on `Anthropic` and on `CursorCloud` raises, naming the provider
  and listing what that provider does support
- `auth: subscription` on `OpenAICompatible` raises for the same reason
- an unrecognized value on a non-CLI provider raises — replacing
  `test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated`
- `auth: none` on an OpenAI-compatible provider sends **no** `Authorization`
  header, asserted against a **real local HTTP server that records the request
  it received**, with `OPENAI_API_KEY` exported in the parent — not a stubbed
  client. Same discipline as Phase 9's spawn test: assert on what crossed the
  boundary, not on the arguments handed to a fake.
- `auth: api` on the same provider still sends the key
- each CLI adapter under `none` scrubs exactly what it scrubs under
  `subscription`, and `CursorCli` omits `--api-key`
- `CLAUDE_CODE_OAUTH_TOKEN` still survives under `none`
- a chain containing a provider with an unsupported mode fails before any
  provider is dispatched, rather than relaying to the next one
- `provider_auth_modes` reports `"none"` for a local provider and omits a name
  that resolves to no class

## What breaks

- `test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated` is replaced
  by its inverse.
- Five existing tests change. This list was verified against the test files
  during planning, not assembled from memory:
  - `test_auth_modes_excludes_the_default_routing_alias_but_keeps_real_providers`
    (`test/test_providers.rb`) — expects `mock => "none"` rather than `"api"`.
  - `test_workflow_start_records_the_auth_mode_of_every_provider`
    (`test/test_graph_engine.rb:89`) — same change.
  - `test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated` —
    replaced by its inverse.
  - `test_a_valid_chain_still_dispatches_with_the_auth_guard_in_place` — its
    fixture declares a stray `auth:` on `mock`, which now raises.
  - `test_router_auth_modes_marks_an_invalid_value_without_raising_or_dropping_the_rest`
    — must stop asserting the `"invalid"` label for a provider whose mode is
    now rejected outright.
- An `.agent_hubrc` carrying any `auth:` on `anthropic` or `cursor_cloud` now
  raises when that provider is dispatched. Previously ignored. The failure is
  loud, happens before dispatch, and names both the provider and its supported
  modes.
- An `.agent_hubrc` carrying a misspelled `auth:` on any non-CLI provider now
  raises instead of being silently treated as `api`.
- A previously ignored `auth: none` on an OpenAI-compatible provider now
  actually withholds the credential, which will turn a working authenticated
  call into an auth failure. This is the intended correction, but it is a
  behavior change on an existing config rather than only a new capability.

## What comes after this, and why in that order

Recorded so the sequencing survives the phase that produced it.

1. **This spec** — provider-neutral auth: vocabulary, per-provider defaults,
   validation, and real credential suppression. Nothing downstream is safe
   before enforcement exists, because an audit field that reports a mode nobody
   enforces is a false record dressed as a fix.
2. **Ollama alias and default resolution** — make `type: ollama` behave like the
   name `ollama`, and decide where `OLLAMA_MODEL` is applied. Until a model name
   is resolved before validation rather than inside `build`, no guard that reads
   the model can be relied on.
3. **Cursor execution modes** — after namespacing around `CursorCloud`'s
   existing `mode:` option, and after deciding whether `ToolLoop` should refuse
   to execute `TOOL:` calls for a provider declared read-only. Without that
   decision the feature constrains the Cursor subprocess while leaving the step
   able to write through MCP, which is not what "read-only" will be read to
   mean.
4. **`:cloud` policy and zero-cost reporting** — the `:cloud` guard needs step 2
   to be complete, and `cost_usd = 0.0` needs this spec's enforcement plus an
   explicit redefinition of `priced_calls` from "usage priced" to "cost known".

## Definition of done

`.agent_hubrc` declaring `auth: none` on an OpenAI-compatible provider pointed
at a local endpoint produces a request with no `Authorization` header, with
`OPENAI_API_KEY` exported in the shell — the leak demonstrated in the
Motivation.

That run's `workflow_start` audit event carries `provider_auth_modes` reporting
`"none"` for that provider.

`auth: none` on `anthropic` fails the run before any provider is dispatched,
with a message naming the provider and listing the modes `anthropic` supports.

Every provider without an explicit `auth:` reports exactly what it reports
today: `subscription` for the CLI adapters, `api` for `anthropic`, `openai`,
`openai_compatible`, and `cursor_cloud`.

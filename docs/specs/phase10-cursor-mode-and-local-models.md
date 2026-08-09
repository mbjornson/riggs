# Phase 10 Spec — Cursor Execution Modes and Local Models

Status: approved, not yet implemented
Supersedes: Phase 9 R9.1's "`auth:` on a non-CLI provider is ignored, not validated"
Date: 2026-08-09

## Motivation

Two gaps, joined by one question Riggs currently answers wrong: **who paid for
this step, and what was that step allowed to do?**

### Cursor steps are unrestricted, with no way to say otherwise

`CursorCli` spawns `agent -p <prompt> --output-format text`. The Cursor CLI
documents that mode as having "access to all tools, including write and shell."
Riggs offers no way to constrain it. The CLI itself supports two read-only
modes:

```
--mode <mode>   plan: read-only/planning (analyze, propose plans, no edits).
                ask:  Q&A style for explanations and questions (read-only).
```

A workflow that wants a Cursor step to *analyze* rather than *edit* cannot say
so today. It gets shell access whether it needs it or not.

### A local model bills nobody, and Riggs records that it billed an API account

Local inference already works: `ollama` maps to `OpenAICompatible`, which sets
an `Authorization` header only when a key is present, so no credential is
required. But Phase 9's attribution reports it as metered:

```
auth_modes = {"codex" => "subscription", "ollama" => "api"}
```

A model running on `127.0.0.1` with no credentials bills nobody. `"api"` is a
false record in the field Phase 9 exists to make trustworthy.

Worse, Riggs sends a credential to it. `OpenAICompatible` reads
`options[:api_key] || ENV["OPENAI_API_KEY"] || ENV["OLLAMA_API_KEY"]` and sets
a Bearer header if any is present. Verified against a local HTTP server that
recorded what it received:

```
base_url = localhost (a local ollama endpoint)
Authorization header the LOCAL server received: Bearer <the OPENAI_API_KEY from my shell>
```

That is the Phase 9 failure one layer up: a key exported for one purpose riding
along to a different destination, silently. Here it lands on localhost, which is
low harm — but the same code path sends it wherever `base_url` points.

### "Local" cannot be inferred

Ollama proxies cloud-hosted models through the same local daemon. On the
author's machine:

```
gemma4:31b       31.3B   caps=completion,tools,thinking
qwen3.6:35b      36.0B   caps=vision,completion,tools,thinking
kimi-k2.5:cloud          caps=completion,tools,thinking,vision
```

`kimi-k2.5:cloud` runs on Ollama's servers and bills an Ollama subscription,
while being served through `http://127.0.0.1:11434/v1` exactly like the local
ones. So neither the provider name nor the base URL tells you who pays.

## Non-goals

- **llama.cpp.** A fast follow. Nothing here should make it harder, and the
  `auth: none` mechanism this phase adds is what it will use.
- **Cursor CLI feature parity.** `--output-format json`, `--resume`/`--continue`
  session continuity, `--force`/`--yolo`, and `--auto-review` stay out. This
  phase adds the permission control, not the full surface.
- **Local model discovery.** Riggs will not query `/api/tags` to enumerate
  installed models. The operator names the model.
- **Pricing or context-window table entries for local models.** Windows vary by
  quantization and by how the operator runs the model, so shipping a table would
  be guessing. The existing model-overrides hook already lets an operator supply
  one.
- **Changing the default Cursor permission level.** Unmoded steps stay
  unrestricted. Silently narrowing what existing workflows may do is the trap
  Phase 9's scrub already sprang once; this phase documents the default instead.

## Decisions

Recorded with their reasoning so they do not get relitigated.

1. **`mode:` is provider-level only, never step-level.** Riggs already splits
   definition from selection: `.agent_hubrc` *defines* providers and MCP
   servers, and workflows and skills only *select* by name. A permission control
   belongs on the defining side. Step-level `mode:` would let a repo-local
   workflow file choose its own permission level, which is exactly the exposure
   gap #6 tracks.
2. **A misplaced or misspelled `mode:` raises.** A permission control that is
   silently ignored is worse than one that does not exist: the operator believes
   a step was sandboxed when it had shell access. Fail loud.
3. **The auth mode declares who pays, not what Riggs does about it.**
   `subscription` = a vendor subscription. `api` = a metered key. `none` =
   nobody. All three are valid on every provider; the *behavior* each one
   triggers varies by provider kind. An earlier draft required `subscription` to
   be a CLI provider, reasoning from the scrub implementation rather than from
   meaning. Ollama cloud disproved it: a genuine vendor subscription on a
   non-CLI provider, which that rule would have made inexpressible.
4. **`auth:` is now validated on every provider.** Phase 9 R9.1 ignored it on
   non-CLI providers on the grounds that there was no CLI to defer to and a
   stray key was harmless. Once `none` is meaningful there, that stops being
   true: `auth: nonw` would silently fall through to sending your API key — the
   same money-typo trap Phase 9 Decision 2 exists to prevent.
5. **`none` suppresses the credential rather than merely labelling the call.**
   Same principle as Phase 9 Decision 3: scrubbing is a positive action Riggs
   controls and can test, not a prediction about someone else's precedence
   rules. A declaration that does nothing enforceable is a comment.
6. **`cost_usd = 0.0` for `none`, unconditionally.** Phase 7 established
   "unmeasured is `nil`, never `0`", because a zero was indistinguishable from a
   genuinely free call. This narrows that rule rather than breaking it: tokens
   and cost become independent axes. Tokens `nil` means uncounted; cost `nil`
   means unknown price; cost `0.0` means known free, and only an explicit
   operator declaration can produce it. It holds whether or not usage was
   measured, because a free call is free regardless of whether anyone counted
   its tokens.
7. **The `:cloud` guard is a known-bad detector, not an enumeration.** Phase 9
   learned four times that hand-written lists of someone else's states fail,
   because each new escape is a state nobody enumerated. The distinction is
   direction of failure. Those lists claimed to be exhaustive and failed *open*:
   an unlisted state was allowed through. This one fails *closed* when it
   matches, and when it does not match, Riggs is exactly where it would be
   without the check — trusting the operator's declaration. An incomplete list
   opens no hole; it only catches less. Do not "fix" this later by deleting it
   as an enumeration.

## R10.1 The `mode:` provider option

A Cursor provider entry accepts `mode:`, whose value is `plan` or `ask`:

```yaml
providers:
  cursor:      { type: cursor }              # unrestricted: write and shell
  cursor_plan: { type: cursor, mode: plan }  # read-only, proposes plans
  cursor_ask:  { type: cursor, mode: ask }   # read-only, Q&A
```

`CursorCli#argv_for` appends `--mode <value>` when set and appends nothing when
absent, leaving today's behavior byte-identical for every existing config.

`MODES = %w[plan ask]`. An unrecognized value raises `Riggs::Providers::Error`
naming the provider and the two valid values.

`mode:` on a provider that is not a `CursorCli` raises, naming the provider —
see Decision 2.

`auth:` needs no equivalent rule because it has no misplaced case left: after
R10.2 all three of its values are meaningful on every provider. `mode:` is the
opposite — it is meaningful only where a Cursor CLI is being spawned, so
declaring it anywhere else is always a mistake, and the mistake it most likely
represents is an operator who believes they constrained a step.

## R10.2 The `none` auth mode

`Cli::AUTH_MODES` becomes `%w[subscription api none]`. Resolution, casing, and
whitespace trimming are unchanged from Phase 9 R9.1.

Behavior by provider kind:

| | CLI provider | non-CLI provider |
|---|---|---|
| `subscription` | scrub API-key variables from the child (Phase 9 R9.3) | send credentials as configured — mechanically identical to `api` |
| `api` | pass API-key variables through | send the API key |
| `none` | scrub API-key variables from the child | **send no `Authorization` header** |

On a non-CLI provider, `subscription` and `api` are mechanically the same: both
send whatever credential is configured, because a hosted endpoint has no CLI
login to defer to. They differ only in what `provider_auth_modes` records, which
is the point — an Ollama-cloud call and an OpenAI call bill different accounts
and must not be indistinguishable in the audit trail.

Under `none`, `OpenAICompatible` sends no `Authorization` header even when
`options[:api_key]`, `OPENAI_API_KEY`, or `OLLAMA_API_KEY` is set. This is the
enforcement half of Decision 5 and the fix for the leak demonstrated in the
Motivation.

`provider_auth_modes` reports `"none"`.

### Validation moves to every provider

`Router#validate_auth_modes!` drops its `next unless klass && klass <= Cli`
skip, so every name in a dispatch chain is validated. It keeps running before
the dispatch loop and outside the relay rescue, so a bad value fails the run
closed rather than failing over to a provider that costs money.

This supersedes Phase 9 R9.1's rule that `auth:` on a non-CLI provider is
ignored. See Decision 4.

## R10.3 Cost for free providers

`Router#meter` returns `cost_usd: 0.0` when the provider's resolved auth mode is
`none`, without consulting `ModelInfo.cost`, and regardless of whether
`usage[:measured]` is true.

Token counts are unaffected: an unmeasured local call still reports `nil`
tokens. See Decision 6 for why this narrows rather than breaks the Phase 7
invariant.

## R10.4 The `:cloud` contradiction guard

A provider whose resolved auth mode is `none` and whose configured `model` name
ends in `:cloud` raises `Riggs::Providers::Error` from `validate_auth_modes!`,
naming the provider and the model and stating that `:cloud` models run on
Ollama's servers and bill an Ollama subscription, so the entry should declare
`auth: subscription`.

The correct configuration for a cloud-hosted Ollama model is therefore:

```yaml
providers:
  local:  { type: ollama, model: gemma4:31b,      auth: none }
  hosted: { type: ollama, model: kimi-k2.5:cloud, auth: subscription }
```

`hosted` reports `"subscription"` in `provider_auth_modes` and its `cost_usd` is
`nil` — unknown, because no pricing table entry exists for it — rather than
`0.0`.

The guard is complete with respect to where a model name can come from:
`StepNode` has no `model` field, so a model is only ever read from provider
config, which is what `validate_auth_modes!` inspects. There is no runtime path
that substitutes a different model after validation.

Matching is on the literal `:cloud` suffix, case-insensitively, after
whitespace trimming.

## R10.5 Ollama as a documented local provider

No new provider class, alias, or registry entry. `ollama` already resolves to
`OpenAICompatible`, and `Router#build` already defaults `base_url` to
`http://127.0.0.1:11434/v1` and `model` to `llama3`. What changes is that
`auth: none` now makes the record truthful and keeps credentials out of the
request.

Compaction needs nothing. `context_window` on the workflow is the token budget;
`ModelInfo.context_window` returning `nil` for `gemma4:31b` means only that
there is no model-derived ceiling, and the existing model-overrides hook covers
an operator who wants one.

README gains a worked `.agent_hubrc` example showing a local model, a
cloud-hosted Ollama model, and a Cursor provider in each mode, plus an explicit
statement that an unmoded Cursor step can write files and run commands.

## R10.6 Tests

- `--mode` appears in argv for each valid value and is absent when unset
- an unrecognized `mode:` raises, naming the provider and both valid values
- `mode:` on a non-Cursor provider raises
- `auth: none` on an OpenAI-compatible provider sends **no** `Authorization`
  header, asserted against a **real local HTTP server** that records the request
  it received, with `OPENAI_API_KEY` exported in the parent — not a stubbed
  client. Same discipline as Phase 9's spawn test: assert on what crossed the
  boundary, not on the arguments to a fake.
- `auth: api` on the same provider still sends the key
- `auth: none` reports `"none"` in `provider_auth_modes`
- `cost_usd` is `0.0` under `none` for both a measured and an unmeasured call
- `subscription` on a non-CLI provider is accepted and reported, no longer an
  error
- an unrecognized `auth:` on a non-CLI provider now raises — replacing
  `test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated`
- `auth: none` with a `:cloud` model raises; with `auth: subscription` the same
  model is accepted, reports `"subscription"`, and prices `nil`
- a chain containing a misconfigured provider fails before any provider is
  dispatched, rather than relaying

## What breaks

- `test_auth_on_a_non_cli_provider_is_ignored_rather_than_validated` is replaced
  by its inverse.
- An `.agent_hubrc` carrying a stray or misspelled `auth:` on a non-CLI provider
  now raises instead of being ignored. The failure is loud, happens before
  dispatch, and names the provider.

## Definition of done

A workflow step declaring `provider: cursor_plan` runs Cursor in read-only plan
mode, and the spawned argv contains `--mode plan`.

A step declaring a provider with `model: gemma4:31b, auth: none` runs against
the local Ollama daemon with no `Authorization` header on the request, and that
run's `workflow_start` audit event carries `provider_auth_modes` including
`"local": "none"`, with `cost_usd` of `0.0` on the recorded provider call.

Changing that entry to `model: kimi-k2.5:cloud` while leaving `auth: none`
fails the run before dispatch, with a message naming the model and directing
the operator to `auth: subscription`.

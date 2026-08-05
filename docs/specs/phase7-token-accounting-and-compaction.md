# Phase 7 Spec — Token Accounting (#2) and Token-Based Compaction (#3)

Status: approved, not yet implemented
Gaps closed: `docs/gaps.md` #2, #3
Date: 2026-08-04

## Motivation

Providers already parse a `usage` block out of every response and drop it on the
floor at `router.rb:52`. Riggs therefore cannot answer "what did this run cost"
in either tokens or dollars, and — more consequentially — cannot answer "will
the next request fit in the model's context window", which is why
`CONTEXT_LIMITS` counts *steps* rather than tokens and why `ToolLoop`'s message
array grows without any bound at all.

These two gaps ship together because #3 depends on #2 and on nothing else.
Building the measurement without its only consumer would very likely produce the
wrong measurement: compaction needs a per-model context window keyed exactly the
way pricing is keyed, and it needs the measurement available *before* a request
is sent rather than after.

### Reach of `gaps.md` #2's "done when"

The recorded "done when" for #2 read: *"...and the ledger fills itself."*
`docs/token-ledger.md` records per-feature build cost — what the person building
a feature spent building it. Token accounting produces exactly that number for a
feature built by running Riggs workflows, so the line holds for the case it
describes.

It does not reach the ledger's existing rows. Those are Riggs' own features,
built in Claude Code sessions rather than through Riggs, so their figures come
from `/cost` by hand and no amount of provider accounting will supply them. That
is a property of who did the building, not a mismatch between the two numbers.

## Non-goals

- Retroactive backfill of usage for sessions that already exist.
- A token-budget *guardrail* that aborts a run (`max_llm_calls` and
  `timeout_seconds` remain the only hard stops). Compaction degrades; it does
  not fail.
- Compaction of anything other than message history — no summarizing of step
  outputs into memory, no cross-session context.
- Fixing the multi-table `ensure_columns!` migration gap. This phase adds one
  new table and alters none, so it neither needs nor closes that item.

## Stated limitations (design consequences, not defects)

1. **CLI-only chains compact blind.** `claude_cli`, `codex`, `cursor_cli`, and
   `cursor_cloud` report no token usage, so no anchor measurement is ever
   available and every size on such a run is a character estimate. Compaction
   still runs — an unmetered run that would otherwise blow its context degrades
   gracefully rather than erroring — but the reserve is absorbing a much larger
   error, and the run says so once. See R3.5.
2. **Pre-flight sizes are estimates.** Only the anchor (the measured prompt size
   of the previous response) is measured. Turns added since then are estimated.
   The reserve exists to absorb that error.
3. **Redefining `context_window` changes runtime behavior.** A workflow declaring
   `context_window: medium` gets a token budget after this lands rather than a
   6-step window. In most workflows this means *more* history is retained, not
   less.

---

## Shared foundation

### `Riggs::Usage`

Normalizes a vendor `usage` hash into one shape:

```ruby
{ input_tokens:, output_tokens:, cache_read_tokens:, cache_write_tokens:,
  total_tokens:, measured: true|false }
```

| Provider | Source keys |
|---|---|
| `anthropic` | `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` |
| `openai_compatible` | `prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens` |
| `mock` | `{}` — **unmeasured**. Corrected 2026-08-05: it reported string *lengths* as token counts, so every offline run displayed ~4x-inflated numbers labelled measured |
| `cursor_cloud` | `{duration_ms:}` — no token keys, therefore **unmeasured** |
| `cli`, `claude_cli`, `codex_cli`, `cursor_cli` | `{}` — **unmeasured** |

`measured` is true when **at least one recognized token key is present**. It is
explicitly *not* "the hash is non-empty" — `cursor_cloud` returns a non-empty
hash carrying no token data, and that case is the discriminating test.

Unmeasured calls carry `nil` token values, never `0`.

### `Riggs::ModelInfo`

One per-model table, since pricing and context window are keyed identically and
two parallel tables could disagree about which models exist:

```ruby
{ input:, output:, cache_read:, cache_write:, context_window: }
```

Prices are USD per 1,000,000 tokens. The module exposes an `AS_OF` date constant
so a stale table is visible rather than silently trusted.

**Implementation note:** the shipped values must be transcribed from vendor
pricing and model documentation at implementation time. They are not to be
recalled from memory — a confidently wrong price produces a confidently wrong
dollar figure, which is worse than `nil`. Coverage required: the Anthropic Claude
models and the OpenAI models named in each provider's `DEFAULT_MODEL`, plus any
model referenced in `config/riggs/workflows/`.

`.agent_hubrc` overrides per model, merged over the shipped table:

```yaml
providers:
  anthropic:
    pricing:
      claude-opus-5: { input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75 }
    context_windows:
      claude-opus-5: 200000
```

### Schema addition

```sql
CREATE TABLE IF NOT EXISTS riggs_provider_calls (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id        TEXT NOT NULL REFERENCES riggs_sessions(id),
  step_key          TEXT NOT NULL,
  provider          TEXT NOT NULL,
  model             TEXT,
  relay_attempt     INTEGER NOT NULL DEFAULT 1,
  measured          INTEGER NOT NULL DEFAULT 0,
  input_tokens      INTEGER,
  output_tokens     INTEGER,
  cache_read_tokens INTEGER,
  cache_write_tokens INTEGER,
  cost_usd          REAL,
  created_at        DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_riggs_provider_calls_session
  ON riggs_provider_calls(session_id, step_key);
```

Token columns are **nullable with no default**. `NULL` means unmeasured and is
distinct from a genuine `0`. `DEFAULT 0` would erase exactly the distinction this
phase exists to preserve.

---

## Feature #2 — Token accounting

### R2.1 Providers report their model

Every provider adds `model:` to its result hash. Resolution order:

1. `data["model"]` from the response body — preferred, because Anthropic and
   OpenAI both echo the *resolved* model, collapsing aliases such as
   `-latest` to a concrete version.
2. The configured `options[:model]`.
3. `nil`.

CLI providers use the configured value or `nil`. `model` is the join key for
both pricing and context window, so accuracy here bounds the accuracy of both.

### R2.2 Router normalizes and prices

`Providers::Router#call` merges two keys into the returned result:

- `usage:` — the normalized shape from `Riggs::Usage`
- `cost_usd:` — from `Riggs::ModelInfo`, or `nil`

`raw:` retains the untouched vendor response.

Pricing is computed in Router because Router is the only component that resolves
provider configuration (`provider_config(name)` merges hub ← workflow); the
per-model override lives in that configuration and is gone downstream.

`cost_usd` is `nil` — never `0` — when usage is unmeasured, `model` is `nil`, or
the model has no entry in the merged table.

Failover needs no attribution logic for the answering provider: a failed attempt
raises before returning, so only one provider ever produces a result.
`relay_attempt` is already merged at `router.rb:52` and is recorded as-is.

Corrected 2026-08-05: a failed attempt is still a *call*. Metering only the
provider that answered kept dispatched-but-failed attempts out of
`riggs_provider_calls` entirely, so a provider that accepted and billed a
request before timing out on the read was spend with no row — and session
coverage then reported a complete count over a denominator that had already
dropped the failure. `Router#call` takes an `on_failed_attempt:` callback,
invoked per failed attempt as it happens (so a chain that fails outright is
covered too), and the caller records it unmeasured: nil tokens, nil cost, real
`relay_attempt`.

### R2.3 ToolLoop records each call

`ToolLoop` gains an injected `record_call:` callable, following the existing
`persist:` pattern exactly, including nil-safety via `@record_call&.call`.
ToolLoop is the correct site for loop calls because it is the component that
knows both the session and the current step.

`GraphEngine` owns the private `record_provider_call` method that backs it, and
calls that method directly for any provider call it makes outside the loop —
specifically the cross-step compaction summary of R3.4. One recording path,
two callers.

The one-shot `providers:ping` path has no session and records nothing.

### R2.4 Storage API

- `record_provider_call(session_id:, step_key:, provider:, model:, relay_attempt:, usage:, cost_usd:)`
- `session_usage(session_id)` → totals plus `calls`, `measured_calls`, `priced_calls`
- `step_usage(session_id)` → the same, grouped by `step_key`

Aggregates **exclude unmeasured calls from token sums** and unpriced calls from
cost sums, rather than coercing either to zero.

### R2.5 Coverage is reported alongside every total

Two independent counters, because a call can be measured but unpriced (a
self-hosted model with no price entry is both plausible and common):

```
12,400 tokens over 6 of 9 calls · $0.0184 over 6 of 9 priced
```

A total is never displayed without its coverage.

### R2.6 Surfaces

- `riggs workflow:inspect SESSION_ID` — usage block, per-step and total.
- `GET /api/sessions/:id/usage` — JSON, same shape as `session_usage`.
- Web `session_show` — Usage table, following the existing Audit table markup.
- `riggs providers:ping NAME` — prints normalized usage and cost for its single
  call. Sessionless and unpersisted, but it makes "did my pricing override take
  effect?" answerable without running a workflow.

### R2.7 Tests

Named cases, each written before its implementation:

- Per-vendor normalization from fixtures captured from real Anthropic and
  OpenAI response payloads.
- `cursor_cloud`'s `{duration_ms:}` normalizes to unmeasured — the non-empty
  hash that carries no tokens.
- An unmeasured call is excluded from a session total, not summed as zero.
- `.agent_hubrc` pricing overrides the shipped table for the same model.
- An unknown model yields `cost_usd: nil` while tokens still record.
- Mixed measured/unmeasured aggregation reports correct coverage on both counters.
- A relay failover attributes usage and cost to the provider that answered, with
  the correct `relay_attempt`.

---

## Feature #3 — Token-based compaction

### R3.1 `context_window` becomes a token budget

`Loader` accepts either a symbol or an integer:

| Value | Budget |
|---|---|
| `short` | 8,000 |
| `medium` | 32,000 (remains the default) |
| `full` | 128,000 |
| integer | that value, verbatim |

`GraphEngine::CONTEXT_LIMITS` (step counts) is deleted. The workflow composer
(`cli/commands.rb:634`, `:697`) continues emitting `"medium"`.

The effective ceiling for a request is
`min(workflow_budget, model_context_window) - reserve`. When the model is
unknown, the workflow budget alone applies.

`reserve` (default 16,384) and `keep_recent` (default 20,000) are workflow-level
keys alongside `context_window`. They are deliberately not per-step: a single run
compacting under two different policies would make the resulting transcript
impossible to reason about.

Both are **scaled to the budget in force** rather than applied absolutely:

```
reserve     = min(configured_reserve, budget / 4)
keep_recent = min(configured_keep_recent, ceiling / 2)
```

The defaults are Pi's, and Pi pairs them with a ~200,000-token budget. Applied
absolutely to the budgets above they contradict each other: `short` (8,000) less
a 16,384 reserve is a ceiling of 0 — a workflow that can retain nothing — and a
20,000-token `keep_recent` against `medium`'s 15,616 ceiling means compaction can
never split anything and so can never get under the ceiling it just measured.
Scaling makes every budget internally consistent by construction, including
budgets that do not exist yet. The clamp lowers explicitly configured values too:
a reserve or keep_recent that breaks the ceiling is not honourable, since
honouring it produces a workflow that cannot run.

### R3.2 Size estimation

`Riggs::Usage.estimate(messages)` returns an estimated token count.

The anchor is the sum of the prompt-side token fields of the most recent
measured response in the same step — `input_tokens + cache_read_tokens +
cache_write_tokens` (`Riggs::Usage.prompt_tokens`). `input_tokens` alone is
**not** the prompt: the canonical field means *uncached* input, which is the
right basis for pricing and the wrong one for sizing. OpenAI reports a cached
prefix as a subset of `prompt_tokens` that normalization subtracts out;
Anthropic reports it pre-subtracted in a separate field. Either way, anchoring
on `input_tokens` sizes a mostly-cached 100,000-token prompt at 5,000 tokens
and compaction never fires. When no prompt-side field was reported at all the
anchor is `nil` (no anchor), never `0` (an empty prompt).

Turns appended since that response are estimated at 4 characters per token, and
the sum is the estimate. With no anchor available — first call of a step, or an
unmeasured provider — the whole array is estimated by the same heuristic.

The heuristic is deliberately crude. The reserve absorbs its error, and R3.4
recovers from the case where it does not.

### R3.3 Two compaction sites

Both unbounded-growth sites are covered. Covering only one leaves the other
able to fail a run.

- **Cross-step history** — `GraphEngine#build_messages` assembles the prior step
  outputs oldest-first and compacts them when they exceed the ceiling, routing
  the summarization call through the step's own chain and auditing it with
  `site: "cross_step"`.

  Corrected 2026-08-05. As first shipped this site did not compact at all: it
  walked newest-to-oldest and **skipped** any output that would breach the
  ceiling. That silently discarded step outputs with no summary and no event,
  and because the walk kept going, the turn most likely to be dropped was the
  newest one — the immediate handoff to the step being built. R3.6's test
  criterion codified the skip, which is why the contradiction with the
  Definition of Done below survived review.
- **Intra-step tool loop** — `ToolLoop#run` checks the estimate before each
  `@router.call`. Over the ceiling, it compacts.

### R3.4 Compaction strategy

Recent turns are kept verbatim up to `keep_recent` (default 20,000 tokens,
scaled down to half the effective ceiling — see R3.1). Older turns are replaced
by a single `role: "assistant"` summary produced by one call through the same
relay chain.

Rules:

- The summarization call is itself recorded via R2.3, with `step_key` set to the
  originating step. Compaction cost is real cost and is not hidden.
- A summary turn is persisted through the existing `persist:` bridge so a
  resumed session sees the compacted transcript, not the original.
- A `context_compacted` audit event records before/after estimates and the turn
  count collapsed. It flows through the existing event stream with no changes to
  `Riggs::Events`.
- If summarization itself fails, the run drops the oldest turns without
  summarizing rather than aborting, and audits `context_compacted` with
  `strategy: "truncated"`. Degrading beats failing. The rescued exception's
  class and message are reported too — as a `compaction_degraded` audit event,
  or on stderr when no `audit:` callable is wired — so an intentional degrade is
  distinguishable from an unexpected failure. A blanket rescue here has already
  hidden one real defect.
- A pass that changes nothing — nothing old enough to collapse, or a single
  message too large to split — audits `strategy: "noop"` with `before == after`
  and `collapsed: 0`. The event is still emitted: an over-budget request that
  compaction could not reduce is exactly the state an operator must be able to
  see, and suppressing the event would recreate the silent non-compaction R3.5
  exists to prevent.
- Tool-result turns are eligible for summarization; the assistant turn carrying
  `tool_calls` and its matching `tool` turns are collapsed together, never
  split, so the transcript stays structurally valid for the provider.

### R3.5 Unanchored chains are surfaced, not silently degraded

On a chain where no provider reports usage there is no anchor, so every size on
the run is a 4-characters-per-token estimate rather than a measurement.
Compaction still runs on those estimates — at both sites — because a run that
would otherwise blow its context degrades better by compacting than by growing
unbounded. What changes is the error the reserve has to absorb, so the run emits
a one-time `compaction_unanchored` audit event naming the chain and the basis
(`basis: "character_estimate"`). An operator reading the stream can then tell an
estimate-driven compaction from a measured one.

### R3.6 Tests

- `context_window: medium` resolves to 32,000; an integer passes through; an
  unknown symbol falls back to the default.
- The effective ceiling is the lower of workflow budget and model window, less
  reserve.
- Instantiated from `Loader`'s **actual defaults** (not hand-picked numbers):
  every `context_window` word leaves a ceiling greater than zero, and a
  transcript over the default ceiling is compacted below it.
- `build_messages` returns every step output when the budget allows, and
  summarizes rather than discards when it does not — including when the
  offending output is the newest one.
- Cross-step compaction emits a `context_compacted` event carrying
  `site: "cross_step"`.
- A summarization call counts against `max_llm_calls` and inherits the caller's
  remaining timeout, at both sites.
- Every dispatched provider attempt reaches `riggs_provider_calls`, including
  ones that failed, recorded unmeasured.
- A tool loop driven past the ceiling compacts and continues rather than raising.
- The summarization call appears in `riggs_provider_calls` attributed to the
  originating step.
- A failed summarization truncates and audits `strategy: "truncated"`.
- An assistant turn bearing `tool_calls` is never separated from its `tool`
  results by compaction.
- A CLI-only chain emits `compaction_unanchored` naming the chain and the
  estimation basis, once per session across pause/resume.

---

## Sequencing

Unlike Phase 6, these two features **cannot be built in parallel**. #3 consumes
`Riggs::Usage`, `Riggs::ModelInfo`, and the recorded anchor measurement that #2
produces; an agent building compaction against an unbuilt measurement layer would
be writing against a guess.

Feature #2 (R2.1–R2.7) lands first and completely, on a green suite. Feature #3
(R3.1–R3.6) follows. Within #2 there is genuine parallelism — the normalization
and pricing modules are independent of the storage and surfacing work — and the
implementation plan should exploit it where the file ownership is disjoint.

## Definition of done

1. A completed run reports tokens in/out and cost per step and per session, each
   with explicit coverage on both the measured and priced counters.
2. Unmeasured providers are visibly unmeasured everywhere they appear — never
   rendered as zero in any surface.
3. A run whose transcript exceeds the effective ceiling completes by compacting
   instead of erroring, at both the cross-step and intra-step sites.
4. Compaction's own token cost is recorded like any other provider call.
5. `docs/gaps.md` #2 and #3 are struck through as shipped, and #2's "ledger fills
   itself" line is corrected per the Motivation section above.
6. Full suite green, RuboCop clean, pre-commit gate passing.

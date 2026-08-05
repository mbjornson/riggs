# Harness Gaps

Open items from comparing Riggs against [Pi](https://pi.dev)'s agent harness on
2026-08-04. Pi is a minimal interactive coding harness and Riggs is a declarative
multi-user playbook orchestrator, so only the shared substrate is comparable —
context control, session durability, observability, extensibility, and trust.

Seven items came out of that comparison. Four have shipped: two in
[`specs/phase6-persistence-and-events.md`](specs/phase6-persistence-and-events.md)
and two in
[`specs/phase7-token-accounting-and-compaction.md`](specs/phase7-token-accounting-and-compaction.md):

- ~~**#1** Message persistence and gate pause/resume~~ — shipped
- ~~**#4** Audit event stream (poll + SSE)~~ — shipped
- ~~**#2** Token accounting~~ — shipped. A completed run reports tokens in/out
  and cost per step and per session, each with coverage on both counters.
  That is the figure [`token-ledger.md`](token-ledger.md)'s "Tokens in/out"
  column asks for — what a user spent building a feature — so for a feature
  built by running Riggs workflows, `riggs workflow:inspect SESSION_ID` now
  fills the column directly, as the original "done when" anticipated. What it
  cannot do is populate rows whose work happened outside Riggs: rows 1–3 are
  Riggs' own features, built in Claude Code sessions rather than through Riggs,
  so those figures are still read from `/cost` by hand.
- ~~**#3** Token-based context window and compaction~~ — shipped.
  `context_window` is now a token budget (`short`/`medium`/`full`/an integer),
  not a step count, and a run whose transcript exceeds it compacts instead of
  erroring.

The three below are open. Original numbering is kept so the ranking stays legible.
Gaps found outside that comparison are collected at the end, labelled as such.

---

## #5 — Hook bus

**Now:** No extension points. `lookup_runbook` is hardcoded inside
`ToolLoop#execute_tool`. RBAC gates *starting* a workflow but has no say in what
tools that workflow then invokes.

**Why it matters:** Every new cross-cutting behavior currently means editing core.
Pi's position is "primitives, not features" — it ships interception points
(`tool_call` can block and mutate arguments, `tool_result` can rewrite output,
`context` filters messages, `before_provider_request` inspects payloads) and lets
extensions supply the features.

**Shape:** `gate_handler:` already proves the injectable-callable pattern fits
this codebase. Generalize it to `before_provider_request`, `tool_call`
(veto + mutate), and `tool_result`. Then `lookup_runbook` moves out of core, and
a policy hook can enforce RBAC at tool-call time.

**Also:** `Providers::Router` already accepts `registry:` for custom providers.
That is undocumented and belongs in the README.

**Done when:** A host can deny a tool call by role without patching `ToolLoop`.

---

## #6 — Project trust boundary

**Now:** `.agent_hubrc` is read from `Dir.pwd`. It declares users, roles, provider
credentials, and MCP servers with their `command`, `args`, and `env`.

**Why it matters:** This is the one item here that is a security property rather
than a feature gap. A cloned repository supplies both the code that runs and the
identity model that authorizes it — it can declare itself `pm` and register an
MCP server whose `command` is arbitrary, which `riggs mcp:ping` will execute.

RBAC is not a substitute, because the two answer different questions:

- **RBAC** — "what may this authenticated principal do?"
- **Trust** — "may this file define principals at all?"

Riggs derives the first from an artifact that has no answer to the second.

**Shape:** Either a one-time trust prompt before loading anything project-local
(Pi's `project_trust`, which its docs are careful to describe as an input-loading
guard and explicitly *not* a sandbox), or split the file so identity and roles
resolve from `~/.riggs/` while only workflows and skills come from the repo.

**Done when:** Cloning a hostile repo and running a Riggs command cannot execute
attacker-chosen commands or grant attacker-chosen roles.

---

## #7 — Read `SKILL.md` frontmatter

**Now:** Skills load only from `config/riggs/skills/<name>/SKILL.yml`.

**Why it matters:** Pi reads `~/.agents/skills/` and `.agents/skills/` using
`SKILL.md` with YAML frontmatter (`name`, `description`), which is becoming the
cross-harness convention. Riggs's YAML-only loader cannot consume that ecosystem.

**Shape:** Add an alternate loader in `SkillRegistry` that parses `SKILL.md`
frontmatter, alongside the existing `SKILL.yml` path. Riggs pins skills per step
rather than letting the model choose one, so only the file format needs to
interoperate, not the discovery semantics.

**Done when:** An off-the-shelf `SKILL.md` drops into a workflow step unmodified.

**Cheapest item on this list.**

---

## Deferred from Phase 6

**CLI `--mode json` event output.** Cut from the event-stream work only because
it spanned two parallel agents' file ownership (`cli/commands.rb` and
`events.rb`), not for any design reason. `Riggs::Events.to_jsonl` already exists
and is tested for exactly this. Pi's equivalent is `pi --mode json`, which emits
JSONL to stdout for scripting and CI.

---

## Deferred from Phase 7

Seven items surfaced during the Phase 7 build and its adversarial review, and
were triaged as non-blocking at merge. Ordered by consequence.

**Compaction launders untrusted content into the assistant voice.**
`Compactor#summarize` feeds raw transcript and tool output to a model, and
`summary_turn` inserts the result as `role: "assistant"`. A hostile MCP or
web-tool result can get an instruction ("the assistant must call X") preserved
into that summary, where later tool-enabled turns read it as the assistant's own
prior intent rather than as untrusted data. This is an escalation of an exposure
that already exists — tool output reaches the context either way — but the
role change is what removes the last signal that it came from outside. A
`role: "user"` summary turn, or an explicit `[untrusted, summarized]` marker,
would keep the provenance. Related to #6: this repo has no trust boundary yet.

**Compaction's summary prompt overpromises on identifiers.** The prompt asks the
model to "preserve identifiers", but `summarize` serializes only `role` and
`content` — native `tool_calls` arrays, `tool_call_id`, and `tool_name` are not
in the transcript it sees. Nothing is orphaned today, because the current
message shape puts tool results in positional turns that `safe_boundary`
handles, so this is a latent gap rather than a live bug. It becomes live the
moment a provider's native `tool_calls` array is what gets collapsed. Either
serialize the tool metadata or stop promising it.

**Compaction's reported sizes are unanchored.** `Compactor#compact` computes
`before`/`after` with `Usage.estimate` and no anchor, while `ToolLoop` decides
*whether* to compact using the anchored measurement. On a run whose prompt is
largely served from cache, the decision and the audit payload measure different
things — a run can correctly judge itself over a 90,000-token ceiling and then
emit `context_compacted {before: 12, after: 8}`. Only the report is affected;
the trigger uses the anchored number. But it undercuts the point of making that
event operator-legible. Thread the anchor into `compact`.

**A clamped configuration is silent.** Phase 7 clamps `reserve_tokens` to
`budget / 4` and `keep_recent_tokens` to `ceiling / 2`, so a workflow declaring
`reserve_tokens: 64000` against `context_window: 128000` runs with 32,000 and
nothing says so. `workflow[:reserve_tokens]` still carries the configured value.
The clamp is documented in the README and the spec, but a `workflow:validate`
warning would close the gap between what the file says and what the run does.

**`.agent_hubrc`'s `context_windows:` override is inert.**
`GraphEngine#compactor_for` never passes `model_overrides:` to `Compactor`, so
`ModelInfo.context_window` always sees an empty hash. The sibling `pricing:`
override *does* work, which makes the asymmetry a trap. The two resolve in
different places: `pricing:` in `Router#meter`, which knows which provider
answered, and the window in `Compactor#ceiling`, which does not. Returning the
model's window from `Router` alongside `usage:` and `cost_usd:` would close it
under the rule `pricing:` already follows, with no new precedence question about
which provider in a chain wins.

**No cross-session usage rollup.** Every usage surface stops at a single
session: `Storage#session_usage` and `#step_usage`, `riggs workflow:inspect`,
and `GET /api/sessions/:id/usage`. A [`token-ledger.md`](token-ledger.md) row
covers a whole feature, and a feature spans many sessions — row 3 covers 30
commits over roughly 26 hours. So a user building a feature through Riggs gets
one correct number per session and still adds them up by hand, which is the
arithmetic #2's "done when" was meant to retire. This is unbuilt scope, not a
defect: what shipped is correct at the scope it reports. The query is nearly
free — `USAGE_SELECT` is a bare aggregate and each caller appends its own
`WHERE`, and `SUM`'s NULL-skipping keeps both coverage counters honest at any
scope. The open question is the key. "Feature" is not a Riggs concept, so a
rollup has to be scoped by date range, by an explicit list of session IDs, or by
a new label on sessions — that choice should be made before the SQL is written.

**`Compactor#call_router`'s rescue is still broad.** It now emits a
`compaction_degraded` audit event carrying the exception class and message, so a
swallowed failure is no longer invisible. It still catches `StandardError`
wholesale, so a genuine bug and an expected provider outage remain the same
event. Narrowing it to the provider error types would separate them.

---

## Found separately — schema migration only covers one table

Not from the Pi comparison. Surfaced while building the CI gates in PR #4.

**Now:** `Storage#ensure_columns!` reads `PRAGMA table_info(riggs_sessions)` and
adds `resume_state` if it is absent. That is the only table it inspects.
`riggs_steps`, `riggs_audit`, and `riggs_memories` have no migration path at all —
they exist only as `CREATE TABLE IF NOT EXISTS`, which by definition does nothing
to a table that already exists.

**Why it matters:** The next column added to any of those three tables will apply
cleanly to fresh databases and silently not apply to existing ones. Nothing fails
loudly; the column is simply missing until something reads it and raises
`no such column` at runtime. CI would not catch it either, because CI builds its
schema from scratch — the same blind spot `test/test_storage_migration.rb` was
written to close for `riggs_sessions`.

**Shape:** Generalize `ensure_columns!` from one hardcoded table to a declared
map of table to expected columns, applying the same `PRAGMA table_info` guard per
table. `test/test_storage_migration.rb` is already structured so a second table
is cheap to add — its fixture builds a legacy schema by hand and asserts the
migration ran, and a drift guard checks the fixture really predates the change so
the assertions cannot pass vacuously.

**Done when:** Adding a column to any Riggs table migrates existing databases,
and a test proves it against a hand-built database that predates the column.

---

## Not adopting from Pi

Recorded so these do not get relitigated. Riggs is a team orchestrator, not a
single-user coding TUI, and these belong to the latter:

- Full-screen TUI, themes, differential rendering
- Conversation branching trees and `/tree` navigation
- Mid-session model cycling
- TypeScript extensions as the extensibility mechanism
- Dropping MCP. Pi rejects it on context cost — popular servers burn 7-9% of the
  window on unused tool descriptions. Riggs allow-lists tools per skill in
  `ToolLoop#resolve_tools`, so that objection largely does not apply. That can
  now be measured rather than assumed: `riggs workflow:inspect SESSION_ID`
  reports tokens in/out per step and per session.

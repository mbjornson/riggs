# Harness Gaps

Open items from comparing Riggs against [Pi](https://pi.dev)'s agent harness on
2026-08-04. Pi is a minimal interactive coding harness and Riggs is a declarative
multi-user playbook orchestrator, so only the shared substrate is comparable —
context control, session durability, observability, extensibility, and trust.

Seven items came out of that comparison. All seven have shipped:

- ~~**#1** Message persistence and gate pause/resume~~ — shipped
  ([`specs/phase6-persistence-and-events.md`](specs/phase6-persistence-and-events.md))
- ~~**#4** Audit event stream (poll + SSE)~~ — shipped (Phase 6)
- ~~**#2** Token accounting~~ — shipped
  ([`specs/phase7-token-accounting-and-compaction.md`](specs/phase7-token-accounting-and-compaction.md)).
  A completed run reports tokens in/out and cost per step and per session, each
  with coverage on both counters. That is the figure
  [`token-ledger.md`](token-ledger.md)'s "Tokens in/out" column asks for — what
  a user spent building a feature — so for a feature built by running Riggs
  workflows, `riggs workflow:inspect SESSION_ID` now fills the column directly,
  as the original "done when" anticipated. What it cannot do is populate rows
  whose work happened outside Riggs: rows 1–3 are Riggs' own features, built in
  Claude Code sessions rather than through Riggs, so those figures are still
  read from `/cost` by hand.
- ~~**#3** Token-based context window and compaction~~ — shipped (Phase 7).
  `context_window` is now a token budget (`short`/`medium`/`full`/an integer),
  not a step count, and a run whose transcript exceeds it compacts instead of
  erroring.
- ~~**#7** Read `SKILL.md` frontmatter~~ — shipped
  ([`specs/phase8-skill-md-frontmatter.md`](specs/phase8-skill-md-frontmatter.md)).
  A skill bundle may be `SKILL.md` (YAML frontmatter plus a markdown body) or
  `SKILL.yml`, sharing one key space. Discovery is unchanged: `.agents/skills/`
  is deliberately not a root.
- ~~**#5** Hook bus~~ — shipped
  ([`specs/phase11-hook-bus.md`](specs/phase11-hook-bus.md)).
  `Riggs::Hooks` provides `before_provider_request`, `tool_call` (veto + mutate),
  and `tool_result`. `lookup_runbook` lives in `Riggs::BuiltinTools`. A host can
  deny a tool call by role without patching `ToolLoop`. Default policy denies
  non-builtin (MCP) tools when the identity lacks `manage_mcp`.
- ~~**#6** Project trust boundary~~ — shipped
  ([`specs/phase12-project-trust.md`](specs/phase12-project-trust.md)).
  `Identity.load_config` refuses an untrusted project `.agent_hubrc`. Trust is
  recorded under `~/.riggs/` (or `RIGGS_TRUST_HOME`) keyed by project path and
  config fingerprint. `riggs setup` auto-trusts; otherwise run `riggs trust`
  (TTY prompts once). Cloning a hostile repo cannot grant roles or run MCP
  commands until the operator trusts the file.

Gaps found outside that comparison remain below, labelled as such.

---

## ~~#5 — Hook bus~~ — shipped

See [`specs/phase11-hook-bus.md`](specs/phase11-hook-bus.md).

---

## ~~#6 — Project trust boundary~~ — shipped

See [`specs/phase12-project-trust.md`](specs/phase12-project-trust.md).

Takes both halves of the shape above rather than choosing between them: trust
keyed by absolute path gates whether the project tier is read at all, and
identity, roles, providers and MCP definitions move to `~/.riggs/` while the repo
keeps workflows and skills. Per-server MCP approval sits on top, since folder
trust alone lets a later commit introduce a new command silently. Shipped as 11a
(tiers, trust, approval) and 11b (attribution, memory scoping).

**One system, not two.** This landed twice, from opposite ends: `ProjectTrust` on
`main` keyed trust to a SHA256 of the config file, so an edit revoked it, and
prompted on a TTY; `Trust` on the phase-11 branch keyed trust to a path and added
the MCP approvals. The merge kept `Trust` and folded main's two ideas into it —
`Trust::Fingerprint` records the bytes the operator reviewed, `Trust::ConfigGate`
asks once on a TTY before refusing, and `Trust::Legacy` imports the old
`trusted_projects.json` once so nobody re-trusts what they already trusted.
`ProjectTrust` is gone. The global tier is exempt from the gate: `~/.riggs/config.yml`
is the file the operator writes, not one a repository ships.

---

## ~~Deferred from Phase 6 — CLI `--mode json`~~ — shipped

`riggs workflow:run … --mode json` emits one JSONL audit event per line on
stdout via `Riggs::Events.to_jsonl` (Pi's `pi --mode json` equivalent).

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
would keep the provenance. Related to #6: project trust now gates `.agent_hubrc`,
but compaction still launders tool output into the assistant voice.

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

## ~~Found separately — schema migration only covers one table~~ — shipped

`Storage#ensure_columns!` no longer inspects `riggs_sessions` alone. `EXPECTED_COLUMNS`
declares the expected columns for all six tables — sessions, steps, audit, messages,
provider_calls, memories — and the same `PRAGMA table_info` guard runs per table, so a
column added to any of them reaches databases that predate it. Empty hashes are kept for
the tables that have never gained a column, so the next one is a one-line addition.

`test/test_storage_migration.rb` proves it the way the entry asked: a hand-built legacy
`riggs_memories` table missing `context` gains the column on open, with the existing row
preserved and the new column NULL. `test_fixture_really_predates_the_migration` still
guards the fixture so the assertions cannot pass vacuously, and
`test_both_declarations_of_riggs_sessions_agree` covers the second declaration in
Storage's embedded fallback heredoc drifting from `db/init_riggs_schema.sql`.

---

## Found separately — three more `Psych.safe_load` sites carry the Phase 8 defect

Not from the Pi comparison. Surfaced by the whole-branch review of Phase 8,
which found and fixed this pattern in the skill loader and then noticed the same
two lines elsewhere.

**Now:** Phase 8 hardened both skill-loading call sites. The three other
sites (identity, workflow loader, web YAML) now use the same
`permitted_classes: [Symbol, Date, Time], aliases: false` treatment. The web
YAML path is also size-capped and key-scoped by permission. Left as residual:
JSON request bodies still have no middleware size cap, and MCP stdout lines
are still unbounded.


**Why it matters:** two distinct failure modes, both demonstrated on the skill
path before Phase 8 closed them there.

1. *An ordinary date field crashes the loader.* Psych auto-types an unquoted
   `2026-08-05`, `permitted_classes: [Symbol]` rejects the resulting `Date`, and
   `Psych::DisallowedClass` is `Psych::Exception < RuntimeError` — not a
   `SyntaxError`. So a workflow file with a `created:` line raises rather than
   reporting a readable error.
2. *A YAML alias bomb hangs the process.* `Psych.safe_load` returns fast because
   aliases are shared references, but `Identity.deep_symbolize` then rebuilds
   the structure and materializes every leaf. On the skill path a 478-byte file
   drove RSS past 8 GB and never returned. The web site is the sharp one: it
   parses YAML straight from a request parameter, so this is reachable by
   anyone who can reach that endpoint.

**Shape:** apply the Phase 8 treatment — `permitted_classes: [Symbol, Date,
Time]`, `aliases: false`, and a rescue naming `Psych::Exception` that turns a
bad document into an error the caller can report. The web endpoint additionally
wants a size cap, since it is the only one of the three that parses input Riggs
never wrote to disk itself.

**Done when:** a date-bearing workflow file loads, an anchor-bearing one is
rejected with a readable error rather than hanging, and a test covers both for
each of the three sites.

---

## Found separately — no size cap on a skill file before it is read

From the adversarial review of Phase 8. Recorded rather than fixed, to keep that
branch scoped to the fail-open defect the same review found.

**Now:** `SkillRegistry#skill_source` calls `File.read` on `SKILL.yml` or
`SKILL.md` with no size check, and `SkillFrontmatter.parse` then makes two more
full copies of a `SKILL.md` (`normalize` strips the BOM and rewrites CRLF) plus
an array of every line. Enumeration touches every skill directory, so the cost
is paid by `skills:list`, the web Skills table, and workflow startup even when
the oversized skill is not the one being run.

**Why it matters:** it is the weakest of the three findings from that review and
is recorded for completeness, not urgency. Reaching it needs write access to
`config/riggs/skills/`, which is the operator's own directory — the realistic
route is importing a skill bundle without reading it. The unbounded `File.read`
predates Phase 8 (`main` reads `SKILL.yml` the same way); what Phase 8 adds is
the `.md` container and its extra copies.

**Shape:** stat the file and skip it with the existing "riggs: skipping skill
at ..." warning when it exceeds a cap, before any read. The cap belongs next to
`SkillFrontmatter::MAX_NESTING_DEPTH`, which guards the same class of input for
the same reason.

**Done when:** an oversized `SKILL.md` and an oversized `SKILL.yml` are each
skipped with a warning naming the path, a sibling skill in the same root still
loads, and neither is ever passed to `File.read`.

---

## Subagents — a step cannot call another playbook

Raised while dogfooding riggs against a second repository.

**Now:** `StepNode` carries an `agent:` field, but it is a label, not a spawn. Its
only runtime use is `graph_engine.rb:352`, which interpolates the name into the
system prompt: `"You are agent 'triage_bot' in Riggs playbook 'example_triage'."`
Execution is a single-cursor walk — `while current` (`graph_engine.rb:167`)
advances one step at a time through `next:` conditional routing, and every step
writes into one flat `@outputs` hash keyed by both `output_var` and step id.
Steps can name different skills and different providers, so one playbook already
spans personas and models; they just share one context, one namespace, and one
process.

**Why it matters:** two things a PM-centric harness wants are currently
unreachable. A playbook cannot reuse another playbook, so every composite
workflow is copy-paste and a fix to the copied steps does not propagate. And
nothing can fan out: reviewing five files, or asking three providers the same
question to compare, has to be written as five hand-numbered sequential steps
whose outputs the author names and re-merges by hand.

**Shape:** nested invocation first, because it needs no new execution model — a
step that names a playbook instead of carrying a prompt, loaded through
`Workflow::Loader` and run on a child `GraphEngine`, with the child's terminal
output bound to the parent's `output_var`. Trust and skills already resolve per
tier, so a nested playbook is gated by the same rules as the outer one. Three
things do not come for free. The child needs its own `@outputs`, or a step id
reused across two playbooks silently overwrites the parent's variable.
`max_llm_calls` has to be charged against the parent's budget rather than
restarting at the child, or a nested call is an unbounded spend wearing a
budget's clothes. And a playbook that eventually calls itself has to be refused
at load rather than discovered at runtime.

Parallel fan-out is the harder half and belongs in its own entry: `while current`
assumes exactly one cursor, and joining N results means deciding what a single
`output_var` holds when N steps wrote to it.

**Done when:** a step can name another playbook, the child's result lands in the
parent's `output_var`, a child cannot overwrite a parent variable it does not
own, a nested run's spend counts against the parent's `max_llm_calls`, and a
cycle is refused with a readable error rather than recursing.

---

## Decided, not a gap — `/api/skills` reports skill text verbatim

From the same adversarial review. Recorded so it reads as a decision rather
than an oversight the next time someone greps for unsanitized output.

**Now:** skill text reaches a terminal through three surfaces. Two are
sanitized: the CLI (`skills:list`, `skills:show`) and the registry's
"skipping skill" warning both go through `Riggs.sanitize_for_terminal`, as does
every HTML view via the `h` helper in `web/app.rb`. `/api/skills` does not.

**Why that is deliberate:** JSON already encodes a control byte correctly on
the wire as a `\u001b` escape — nothing raw is emitted. The exposure needs a
consumer that parses the JSON and prints the decoded string straight to a
terminal, e.g. `curl -s /api/skills | jq -r '.[].description'`. Sanitizing the
payload to cover that would make the API disagree with the file on disk, so a
client could no longer read back what a skill actually declares. The HTML view
is a rendering and may drop bytes that cannot render; an API response is not.

`test_skills_api_reports_the_description_faithfully` pins the round-trip, so
this cannot be "fixed" by accident.

**Revisit if:** Riggs ever ships a client of its own that prints API output to
a terminal. That client sanitizes at its own print boundary — the same rule the
CLI already follows — rather than the server mangling the payload for everyone.

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

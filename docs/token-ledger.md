# Token Ledger

Actuals per feature, recorded at completion. Same format and protocol as
agentcrm's `docs/superpowers/token-ledger.md` — after a few rows, estimating a
new feature is a lookup (tasks × historical per-task average), not a guess.

**Protocol (at feature completion):**
1. Run `/cost` (or read the session usage panel) and record tokens in/out for
   the session span the feature occupied.
2. Fill the mechanical columns from git (`git diff --shortstat <before> <after>`,
   commit timestamps, test run count).
3. Note agent runs, including failed/stalled ones — failures are cost.

| # | Feature | Date | Branch / PR | Plan tasks | Commits | Files | LOC +/− | Suite runs at end | Agent runs (failures) | Build span (first→last commit) | Tokens in/out | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Phase 6 — message persistence + gate resume, audit event stream | 2026-08-04 | `phase-6-persistence-and-events` / #3 | 10 (R1.1–R1.5, R4.1–R4.5) | 1 | 20 | +1837/−32 | 122 | 2 impl (0 failed) + 1 Codex review | single commit | see session note ↓ | 2 agents in parallel on disjoint files over a shared storage layer landed first. Codex review found 4×P1 + 1×P2, all confirmed real, all fixed before merge |
| 2 | Commit-time and CI quality gates | 2026-08-04 | `ci-commit-gates` / #4 | 3 | 3 | 9 | +457/−2 | 129 | 1 (0 failed) | 9m (14:23→14:32) | see session note ↓ | Pre-commit hook, gem-packaging gate, migration test. `docs/gaps.md` + this file folded in |
| 3 | Phase 7 — token accounting + token-based compaction (closes `docs/gaps.md` #2, #3) | 2026-08-05 | `phase-7-token-accounting` / not yet opened | 13 (+ Task 2b, inserted mid-flight for promotional pricing) | 22 | 35 | +4550/−61 | 219 | ~20 (14 implementers incl. 2b, 0 abandoned; 6 fix rounds — Tasks 2, 3, 7, 10, 11, 12; 1 stalled/resumed — Task 11) | ~22h36m (2026-08-04 15:04→2026-08-05 13:40) | see session note ↓ | Not parallelizable like Phase 6: #3 (compaction) consumes #2's (accounting) measurement layer, so Phase A shipped completely on a green suite before Phase B started. Reviewer found and fixed 6+ plan-authored defects along the way (vacuous tests, wrong SQL, a swallowed-exception bug that would have silently defeated summarization in production) — see `.superpowers/sdd/2026-08-04-phase7-token-accounting/progress.md` |

**Session note (rows 1–2).** Both features were built in one Claude Code session,
so the token and cost figures are session-wide and **cannot be split between the
rows**: 134.0k input / 249.1k output (112.4k/6.8k Haiku 4.5, 21.6k/242.3k Opus 5),
57.8m cache read, 1.4m cache write, $46.99, 1h 1m API time across 6h 28m wall.
That total also covers the pi.dev research and `docs/gaps.md`, neither of which is
a row here. Treat it as a ceiling for the two rows combined, not a per-feature
number — the first per-feature figure will come from the next single-feature session.

The session reported 2464 lines added / 95 removed against 2294/34 actually
committed. The difference is exploratory work, mutation testing, and reverted
probes. Per the protocol above, that is real cost and is deliberately not netted out.

**Session note (row 3).** Tokens in/out are not recorded for this row. Step 1
of the protocol above ("run `/cost` or read the session usage panel") requires
a human to read a panel this recording pass has no access to, so the cell is
left as `see session note` rather than estimated or backed into from any other
number — per the protocol's own rule, an unmeasured figure is not a zero. Fill
in from the usage panel when available, following the per-feature (not
session-wide) convention rows 1–2 were unable to establish.

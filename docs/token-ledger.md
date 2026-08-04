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

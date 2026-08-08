# Riggs

Declarative YAML playbooks for multi-step AI automations — CLI-first Ruby gem with optional Rails engine, SQLite persistence, HITL gates, provider relay chains, skills, MCP tools, and sqlite-memory semantic recall (FTS5 fallback).

## Requirements

- Ruby >= 4.0
- SQLite3
- Optional: [sqlite-vector](https://github.com/sqliteai/sqlite-vector) + [sqlite-memory](https://github.com/sqliteai/sqlite-memory) for hybrid semantic search

## Quick start

### Standalone (`riggs serve`)

```bash
bundle install
bundle exec rake install   # or use bin/riggs from the repo
cd /path/to/your/project
riggs setup
riggs identity:show
riggs config:show
riggs workflow:validate example_triage
riggs workflow:simulate example_triage
riggs workflow:run example_triage --ticket="Login ERROR timeout" --auto-approve
riggs memory:persist "Users hit OAuth expiry on login"
riggs memory:recall "OAuth login"

# Web UI + JSON API (no Rails required)
riggs serve --port 4567
# open http://127.0.0.1:4567 — switch user, edit config, run playbooks
```

Auth for the web app: logged-in cookie (User page), `X-Riggs-User` header, `?user=`, or `Riggs.identity_mapper` in a host process.

## Identity & RBAC

`.agent_hubrc` defines users and roles:

| Role | Permissions |
|------|-------------|
| pm | edit_workflow, manage_skills, configure_memory, publish, read_workflow, inspect_run |
| engineer | run_workflow, approve_gates, read_workflow, inspect_run |
| viewer | read_workflow, inspect_run |

```bash
riggs identity:show --user=pm_alice
riggs workflow:run example_triage --user=eng_bob --auto-approve
```

## Playbooks

Workflows live in `config/riggs/workflows/*.yml`. See `example_triage.yml` for branching (`if contains ERROR`), HITL (`gates: [approval]`), templates (`{{workflow.step.var}}`), and `max_llm_calls` / `timeout_seconds` guardrails.

Three more keys govern the token budget (all optional; defaults shown):

```yaml
context_window: medium      # short (8,000) | medium (32,000) | full (128,000) | an integer token budget
reserve_tokens: 16384       # headroom that absorbs pre-flight estimation error (capped at a quarter of the budget)
keep_recent_tokens: 20000   # most recent turns kept verbatim when compacting (capped at half the ceiling)
```

The budget in force for a request is the workflow's `context_window`, or the model's own context window when that is lower and the model is known — the intra-step tool loop knows the model it last called, while cross-step history is selected before any model has been chosen and so is budgeted by `context_window` alone. The effective ceiling is that budget less `reserve_tokens`.

Both derived knobs are scaled to the budget in force: `reserve_tokens` is capped at a quarter of it, and `keep_recent_tokens` at half the resulting ceiling. The cap applies to explicitly configured values too. The defaults suit a large budget; taken literally against `context_window: short` a 16,384-token reserve would leave a ceiling of 0, and against `medium` a 20,000-token keep_recent is larger than the ceiling compaction is trying to get under — a value that breaks the ceiling is lowered rather than honoured.

When a transcript — cross-step history or an in-progress tool loop — would exceed the ceiling, Riggs summarizes older turns through the same relay chain and keeps the most recent turns verbatim, rather than growing the request unbounded or erroring. `riggs workflow:inspect SESSION_ID` reports tokens in/out and cost per step and per session, each with explicit coverage (e.g. `12,400 tokens over 6 of 9 calls · $0.0184 over 6 of 9 priced`) — unmeasured or unpriced calls are never shown as zero.

```bash
# Interactive composer (TTY): prompts for triggers, relay_chain, steps, gates
riggs workflow:new my_playbook

# Scripts / CI: skip prompts
riggs workflow:new my_playbook --non-interactive --trigger=keyword --keywords=triage,ticket
```

Hand-edit YAML anytime; `workflow:validate` / the composer’s post-write check catch cycles and bad `next` refs.

## Triggers

Playbooks declare `triggers:` (manual and/or keyword). Keyword match is used to find which playbook fits incoming text; manual means “run from CLI/UI” and does not match arbitrary text by itself.

```yaml
triggers:
  - type: manual
  - type: keyword
    keywords: [triage, ticket]
```

```bash
riggs triggers:list
riggs triggers:match "please triage this"
```

Web: `/triggers` and `GET /api/triggers/match?q=…` (requires `read_workflow`).

## Providers & relay chain

HTTP providers (direct API):

| Name | Backend | Auth |
|------|---------|------|
| `mock` | Deterministic offline | — |
| `claude` / `anthropic` | Anthropic Messages API | `ANTHROPIC_API_KEY` |
| `openai` | OpenAI-compatible chat | `OPENAI_API_KEY` |
| `ollama` | Local OpenAI-compatible | optional |

CLI providers (shell out; binaries must be on `PATH`). These run against your
**subscription** by default — Riggs removes the API-key variables from the
*inherited environment* before spawning the child, so an exported key in your
shell cannot reach the CLI and override its own stored login (`codex login`,
`claude /login`, `cursor-agent login`). Set `auth: api` on the provider to bill
metered API credits instead.

| Name | Command | `auth: subscription` (default) | `auth: api` |
|------|---------|-------------------------------|-------------|
| `cursor` | `agent -p … --output-format text` | `cursor-agent login` | `CURSOR_API_KEY` |
| `claude_cli` | `claude -p … --bare` | `claude /login`, or `CLAUDE_CODE_OAUTH_TOKEN` | `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` |
| `codex` | `codex exec …` | `codex login` | `CODEX_API_KEY` or `OPENAI_API_KEY` |

```yaml
# .agent_hubrc
providers:
  codex:      { type: codex }                  # uses your ChatGPT subscription
  claude_api: { type: claude_cli, auth: api }  # bills ANTHROPIC_API_KEY
```

`ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` both override a Claude Pro/Max
subscription when Claude Code sees them, so `auth: subscription` unsets both
for the child rather than trusting them to be absent.

**What the scrub covers, and what it does not.** The scrub removes its
provider's API-key variables from the environment Riggs hands to the child
process — the channel demonstrated in the spec's Motivation, and the only one
Riggs controls. It does not reach credentials the CLI reads from its own
configuration: Claude Code's `settings.json` `env` block and an
`apiKeyHelper` hook can both supply a key independent of the process
environment, and the cloud-provider gateway variables
(`ANTHROPIC_AWS_API_KEY`, `ANTHROPIC_FOUNDRY_API_KEY`,
`ANTHROPIC_FOUNDRY_AUTH_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK`) are deliberately
left unscrubbed. See "Known residual auth paths" in
[`docs/specs/phase9-cli-subscription-auth.md`](docs/specs/phase9-cli-subscription-auth.md)
for why.

Cursor Cloud Agents (async REST — needs a repo):

| Name | API | Auth |
|------|-----|------|
| `cursor_cloud` | `POST https://api.cursor.com/v1/agents` + poll run | `CURSOR_API_KEY` |

```yaml
# playbook
providers:
  default:
    relay_chain: [cursor, claude_cli, mock]

# .agent_hubrc
providers:
  cursor_cloud:
    type: cursor_cloud
    model: composer-2.5
    repos:
      - url: "https://github.com/org/repo"
        startingRef: main
```

```bash
export CURSOR_API_KEY=…
riggs providers:ping mock
riggs providers:ping cursor
```

**CLI vs cloud:** use `cursor` / `claude_cli` / `codex` for short playbook steps. Use `cursor_cloud` when the step should run a full Cursor cloud agent against a git repo (heavier, slower, requires `repos:`).

Configure credentials via env or `.agent_hubrc` `providers:`.

**Unmetered chains.** `cursor`, `cursor_cli`, `cursor_cloud`, `claude_cli`, `anthropic_cli`, `codex`, and `openai_cli` report no token usage — there is nothing in their response to measure. On a relay chain built entirely from those providers there is never an anchor, so every size Riggs computes on that run is a 4-characters-per-token estimate rather than a measurement. Compaction still runs on those estimates, at both the cross-step and tool-loop sites — a run that would otherwise blow its context degrades better by compacting than by growing unbounded — but `reserve_tokens` is absorbing a much larger error than on a metered chain. The run logs one `compaction_unanchored` audit event (`{chain: [...], basis: "character_estimate"}`) per session to say so.

### Pricing and context windows

`Riggs::ModelInfo::TABLE` ships one row per model with both its price (USD per 1,000,000 tokens) and its context window, since the two are keyed identically. `Riggs::ModelInfo::AS_OF` is the date those numbers were last checked against vendor pricing pages — treat a stale `AS_OF` as a reason to re-verify before trusting a cost figure. `.agent_hubrc` `pricing:` overrides the shipped rate for a model by name and take effect immediately on every `cost_usd` reported for that provider:

```yaml
# .agent_hubrc
providers:
  anthropic:
    pricing:
      claude-opus-5: { input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75 }
```

Some shipped table rows also carry a `promotional:` overlay — its own `input`/`output`/`cache_read`/`cache_write` rates plus an `until:` date (inclusive). While the promo is live it is used in place of the base rate automatically; once `until` passes, the base rate applies again with no table edit required. A `.agent_hubrc` override always wins over both the base rate and any live promotional rate.

The spec also defines a same-shaped `context_windows:` override block (`context_windows: { claude-opus-5: 200000 }`) for overriding a model's context window rather than its price, and `Workflow::Compactor` accepts it as a `model_overrides:` constructor argument. As shipped, `GraphEngine` does not read `.agent_hubrc`'s `context_windows:` block into that argument, so declaring one today has no runtime effect — only `pricing:` is wired end to end from `.agent_hubrc`.

## Memory (sqlite-memory)

```bash
export RIGGS_VECTOR_EXT=/path/to/vector
export RIGGS_MEMORY_EXT=/path/to/memory
export RIGGS_EMBED_MODEL=/path/to/nomic-embed-text.gguf
```

If extensions are missing, Riggs automatically uses namespaced FTS5 in `riggs_memories`.

## Skills & MCP

Skills live in `config/riggs/skills/<name>/SKILL.yml` (optional `prompt.md`). Load by name or pin a version:

```bash
riggs skills:list
riggs skills:show triage_v1
riggs skills:show triage_v1@1.0.0
```

A skill bundle is a directory under `config/riggs/skills/` holding either
`SKILL.yml` or `SKILL.md`. Both containers use the same keys — `name`,
`version`, `description`, `system_prompt`, `tools`, `mcp_servers`.

`SKILL.md` is the cross-harness convention: YAML frontmatter, then the
instructions as a markdown body.

```markdown
---
name: code-reviewer
description: Reviews a diff for correctness and clarity.
---

Review the diff. Report correctness problems before style ones.
```

The body becomes the skill's system prompt, so an off-the-shelf `SKILL.md`
works unmodified. A `system_prompt:` key in frontmatter takes precedence over
the body, and the body takes precedence over a `prompt.md` file beside it.
`tools:` and `mcp_servers:` work in frontmatter too, so an imported skill can
gain a Riggs tool without being converted.

If a directory holds both files, `SKILL.yml` wins. A skill file that fails to
parse is skipped with a warning naming it; the other skills still load.

Riggs does not read `.agents/skills/`. Copy the skill directory into
`config/riggs/skills/`.

Skill YAML may declare `tools:` and optional `mcp_servers:` allow-list. GraphEngine runs a multi-turn tool loop: provider may return native `tool_calls` (Anthropic/OpenAI) or `TOOL:name|{json}` (Mock/CLI fallback), results are executed via MCP or built-ins (`lookup_runbook`), then fed back until final text.

Configure multiple MCP servers in `.agent_hubrc`:

```yaml
mcp_servers:
  github:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "…"
```

```bash
riggs mcp:list          # engineer (manage_mcp)
riggs mcp:ping github
```

**Note:** Cursor/Claude/Codex CLI providers do not use native tool APIs yet — tools are advertised in the system prompt and `TOOL:` lines are parsed.

## Rails host vs standalone

**Standalone** — CLI + `riggs serve` against `Dir.pwd` (`.agent_hubrc` + `db/riggs.sqlite3`). Best for PM config and engineer ops without a Rails app.

**Rails host** — optional thin engine that mounts the same Rack app:

```ruby
# Gemfile
gem "riggs"
gem "rails" # host app only

# config/routes.rb
mount Riggs::Engine => "/riggs"

# optional identity bridge
Riggs.identity_mapper = ->(request) {
  # map host current_user → hubrc user key
  request.env["warden"]&.user&.riggs_user_id
}
```

Pass identity with `X-Riggs-User`, the web User picker, or `Riggs.identity_mapper`. There is no duplicated controller logic — Engine routes forward to `Riggs::Web::App`.

### PM configuration walkthrough

1. `riggs setup` (or open Config in the web UI).
2. As a PM user, edit users/roles, providers, MCP servers, and memory paths under **Config** (or `PATCH /api/config`).
3. Add playbooks under `config/riggs/workflows/` (CLI `workflow:new` or hand-edit YAML).
4. Engineers run playbooks from **Playbooks** or `riggs workflow:run`; approve HITL via **Runs** (`POST /api/sessions/:id/approve|reject`) — the decision is audited, and approving a run that paused at a gate resumes it from that step. Resume from the CLI with `riggs workflow:resume <session_id>`.
5. Inspect memory under **Memory** (`GET /api/memory/search?q=`).

Stable JSON API (same app): `GET/PATCH /api/config`, `GET /api/workflows`, `POST /api/workflows/:name/run`, `GET /api/sessions/:id`, `GET /api/sessions/:id/audit`, `GET /api/sessions/:id/events?after=`, `GET /api/sessions/:id/stream` (SSE), `POST .../approve|reject`, `GET /api/memory/search`, `GET /api/skills`, `GET /api/mcp/servers`, `GET /api/triggers`, `GET /api/triggers/match?q=`.

## Development

```bash
bundle exec rake test
bundle exec rubocop
```

Default CI is Rails-free (Ruby 4.0 + Rack::Test). sqlite-memory extensions are optional locally via `RIGGS_VECTOR_EXT` / `RIGGS_MEMORY_EXT` / `RIGGS_EMBED_MODEL` — CI uses the FTS fallback.

### Commit-time gate

`bin/setup` points git at the tracked hooks directory. On a fresh clone, run it (or the one-liner) once:

```bash
bin/setup                              # bundle install + hook wiring
git config core.hooksPath .githooks    # equivalent, if you only want the hook
```

[`.githooks/pre-commit`](.githooks/pre-commit) then runs `bundle exec rubocop` followed by `bundle exec rake test` (~3s total) and blocks the commit on the first failure, naming the gate that failed.

```bash
git commit --no-verify   # skip every commit-time gate for one commit
```

It checks the **working tree, not the index**, and deliberately does not stash: an interrupted hook must never be able to strand uncommitted work in a stash. If you are committing part of a dirty tree, the gate can fail on changes you have not staged yet.

### Cutting a release

1. Bump [`lib/riggs/version.rb`](lib/riggs/version.rb) and update [`CHANGELOG.md`](CHANGELOG.md).
2. Ensure Phase 4+ sources are tracked (`lib/riggs/web/**`, `config_store.rb`) so `gem build` includes them (`git ls-files` drives the gemspec). CI enforces this: it builds the gem and fails if any file on disk under `lib/` or `exe/` is absent from the package.
3. `bundle exec rake test && bundle exec rubocop`
4. `gem build riggs.gemspec` then publish when ready (`gem push` — not automated here).

## License

MIT

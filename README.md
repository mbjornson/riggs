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

CLI providers (shell out; binaries must be on `PATH`):

| Name | Command | Auth |
|------|---------|------|
| `cursor` | `agent -p … --output-format text` | `CURSOR_API_KEY` |
| `claude_cli` | `claude -p … --bare` | `ANTHROPIC_API_KEY` |
| `codex` | `codex exec …` | `CODEX_API_KEY` or `OPENAI_API_KEY` |

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
4. Engineers run playbooks from **Playbooks** or `riggs workflow:run`; approve HITL via **Runs** (`POST /api/sessions/:id/approve|reject`) — decision is audited; interactive resume still works best from CLI until full pause/resume storage lands.
5. Inspect memory under **Memory** (`GET /api/memory/search?q=`).

Stable JSON API (same app): `GET/PATCH /api/config`, `GET /api/workflows`, `POST /api/workflows/:name/run`, `GET /api/sessions/:id`, `GET /api/sessions/:id/audit`, `POST .../approve|reject`, `GET /api/memory/search`, `GET /api/skills`, `GET /api/mcp/servers`, `GET /api/triggers`, `GET /api/triggers/match?q=`.

## Development

```bash
bundle exec rake test
bundle exec rubocop
```

Default CI is Rails-free (Ruby 4.0 + Rack::Test). sqlite-memory extensions are optional locally via `RIGGS_VECTOR_EXT` / `RIGGS_MEMORY_EXT` / `RIGGS_EMBED_MODEL` — CI uses the FTS fallback.

### Cutting a release

1. Bump [`lib/riggs/version.rb`](lib/riggs/version.rb) and update [`CHANGELOG.md`](CHANGELOG.md).
2. Ensure Phase 4+ sources are tracked (`lib/riggs/web/**`, `config_store.rb`) so `gem build` includes them (`git ls-files` drives the gemspec).
3. `bundle exec rake test && bundle exec rubocop`
4. `gem build riggs.gemspec` then publish when ready (`gem push` — not automated here).

## License

MIT

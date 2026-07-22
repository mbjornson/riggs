# Riggs

Declarative YAML playbooks for multi-step AI automations — CLI-first Ruby gem with optional Rails engine, SQLite persistence, HITL gates, provider relay chains, skills, MCP tools, and sqlite-memory semantic recall (FTS5 fallback).

## Requirements

- Ruby >= 4.0
- SQLite3
- Optional: [sqlite-vector](https://github.com/sqliteai/sqlite-vector) + [sqlite-memory](https://github.com/sqliteai/sqlite-memory) for hybrid semantic search

## Quick start

```bash
bundle install
bundle exec rake install   # or use bin/riggs from the repo
cd /path/to/your/project
riggs setup
riggs identity:show
riggs workflow:validate example_triage
riggs workflow:simulate example_triage
riggs workflow:run example_triage --ticket="Login ERROR timeout" --auto-approve
riggs memory:persist "Users hit OAuth expiry on login"
riggs memory:recall "OAuth login"
```

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
riggs workflow:new my_playbook
```

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

## Rails engine

```ruby
# Gemfile
gem "riggs"
gem "rails" # host app

# config/routes.rb
mount Riggs::Engine => "/riggs"
```

Pass identity with `X-Riggs-User` header or map `current_user` via a host helper.

## Development

```bash
bundle exec rake test
```

## License

MIT

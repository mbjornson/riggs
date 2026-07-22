# Changelog

## 0.1.0

- Phase 1: CLI setup, RBAC identity, YAML loader/validate/simulate, GraphEngine with HITL, SQLite sessions/steps/audit, MemoryService (sqlite-memory + FTS fallback)
- Phase 2: ProviderRouter with Mock, Anthropic, OpenAI-compatible/Ollama relay_chain failover; CLI transports (`cursor`, `claude_cli`, `codex`); Cursor Cloud Agents (`cursor_cloud`); workflow provider config merge; `providers:ping`
- Phase 3: SkillRegistry version pins + tool defs; MCP multi-server Manager; GraphEngine ToolLoop with native tool_calls (Anthropic/OpenAI) and TOOL: fallback; `skills:show`, `mcp:list`/`mcp:ping`; engineer `manage_mcp`
- Phase 4: Framework-agnostic `Riggs::Web::App` (Rack) + `riggs serve`; ConfigStore / PM config UI; JSON API; thin Rails Engine mount of the same app
- Phase 5: Keyword/manual triggers CLI + `/api/triggers`; interactive `workflow:new` composer (`--non-interactive` for CI); docs and release hygiene

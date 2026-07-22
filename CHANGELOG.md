# Changelog

## 0.1.0

- Phase 1: CLI setup, RBAC identity, YAML loader/validate/simulate, GraphEngine with HITL, SQLite sessions/steps/audit, MemoryService (sqlite-memory + FTS fallback)
- Phase 2: ProviderRouter with Mock, Anthropic, OpenAI-compatible/Ollama relay_chain failover; CLI transports (`cursor`, `claude_cli`, `codex`); Cursor Cloud Agents (`cursor_cloud`); workflow provider config merge; `providers:ping`
- Phase 3: SkillRegistry + MCP stdio JSON-RPC client hook
- Phase 4: Mountable Rails engine (dashboard, workflows API, sessions/HITL, memory search)
- Phase 5: Keyword/manual triggers, workflow:new template, docs

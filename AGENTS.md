# AGENTS.md

Before doing any work, review `CLAUDE.md` in full.

## Claude Code compatibility

Translate Claude-specific instructions by capability:

- `Read` -> read files with the available file or shell tools.
- `Edit` and `Write` -> use the available patch/edit tool.
- `Glob` and `Grep` -> use `rg --files` and `rg`.
- `Bash` -> use the primary shell execution tool.
- `Skill` -> load and follow the referenced `SKILL.md`.
- `AskUserQuestion` -> use structured user input when available; otherwise ask in chat and wait.
- `WebFetch` and `WebSearch` -> use the relevant web or documentation tool.
- `Task` and Claude subagents -> use available subagent tools only when supported; otherwise work inline.
- Claude slash commands -> use the corresponding Codex skill or custom prompt.
- Unsupported lifecycle tools -> stop and explain the missing capability instead of pretending success.

When `CLAUDE.md` conflicts with this compatibility section, preserve the project intent and translate only the tool invocation. Do not edit `CLAUDE.md` as part of synchronization.

# Phase 12 Project Trust — Implementation Plan

**Goal:** Pi-style project trust before loading `.agent_hubrc` identity/MCP so a hostile clone cannot grant roles or run attacker MCP commands.

**Tech stack:** Ruby 4.0, Minitest, RuboCop, SHA-256 via Digest.

## Files

| File | Action |
|---|---|
| `lib/riggs/project_trust.rb` | Create |
| `lib/riggs/identity.rb` | `ensure!` in `load_config` |
| `lib/riggs/cli/commands.rb` | `trust` command; setup auto-trust; `--mode json` |
| `test/test_helper.rb` | Trust tmp projects |
| `test/test_project_trust.rb` | Create |
| `docs/gaps.md`, `CHANGELOG.md`, `README.md` | Close gaps |

## Tasks

1. Failing tests for untrusted load / fingerprint change / trust command.
2. Implement `ProjectTrust` + Identity choke point.
3. Wire CLI `trust`, setup auto-trust, test helper.
4. Wire `workflow:run --mode json` to emit `Events.to_jsonl` lines.
5. Update gaps.md / CHANGELOG.

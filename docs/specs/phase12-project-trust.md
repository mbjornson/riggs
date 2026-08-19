# Phase 12 Spec — Project Trust Boundary (#6)

Status: implemented
Gaps closed: `docs/gaps.md` #6
Date: 2026-08-16

## Motivation

`.agent_hubrc` is read from `Dir.pwd`. It declares users, roles, provider
credentials, and MCP servers with their `command`, `args`, and `env`. A cloned
repository supplies both the code that runs and the identity model that
authorizes it — it can declare itself `pm` and register an MCP server whose
`command` is arbitrary, which `riggs mcp:ping` will execute.

RBAC answers "what may this authenticated principal do?" Trust answers "may
this file define principals at all?" Riggs currently has no answer to the
second.

## Non-goals

- A sandbox for MCP child processes (Pi's `project_trust` is explicitly an
  input-loading guard, not a sandbox; same here).
- Splitting identity into `~/.riggs/` vs repo workflows (alternate shape from
  the gap; this phase picks the Pi-style prompt).
- Trusting workflow YAML or skill files (separate class of input; skills already
  skip discovery of `.agents/skills/` for this reason).

## Decisions

1. **One-time trust before loading project-local identity/MCP config.** Until
   the project is trusted, `Identity.load_config` refuses to return the file's
   users, roles, providers, or `mcp_servers`.
2. **Trust store under `~/.riggs/trusted_projects.json`** (overridable via
   `RIGGS_TRUST_HOME`). Keyed by absolute project root path, storing a SHA-256
   fingerprint of the trusted `.agent_hubrc` contents. A content change invalidates
   trust and requires re-approval.
3. **Interactive prompt on a TTY; fail closed otherwise.** Non-interactive CI
   must run `riggs trust` (or the test helper's explicit trust) first.
4. **`riggs setup` auto-trusts** the config it just wrote — the operator authored it.
5. **`riggs trust`** records trust for the current project after the operator
   has reviewed the file. No silent trust on first read.

## R12.1 `Riggs::ProjectTrust`

New file `lib/riggs/project_trust.rb`.

```ruby
ProjectTrust.trusted?(project_root, config_path:)  # => bool
ProjectTrust.trust!(project_root, config_path:)    # persist fingerprint
ProjectTrust.ensure!(project_root, config_path:, io: $stderr, stdin: $stdin)
```

`ensure!` returns if trusted; on a TTY prompts
`Trust this project's .agent_hubrc (users/roles/MCP)? [y/N]`; otherwise raises
`Riggs::Error` naming `riggs trust`.

## R12.2 Choke point

`Identity.load_config` calls `ProjectTrust.ensure!` after resolving the path and
before parsing YAML into the returned hash. `ConfigStore#read` goes through the
same path. Workflow/skill loaders do not.

## Done when

Cloning a hostile repo and running a Riggs command cannot execute
attacker-chosen MCP commands or grant attacker-chosen roles — proven by a test
that writes a malicious `.agent_hubrc` in an untrusted temp project and asserts
`Identity.load_config` / MCP entry points raise before spawning.

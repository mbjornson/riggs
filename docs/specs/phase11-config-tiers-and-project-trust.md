# Phase 11 Spec — Config Tiers and Project Trust

Status: approved, not yet implemented
Closes: gap #6 (project trust boundary), `docs/gaps.md`
Date: 2026-08-10

## Motivation

Riggs resolves its entire configuration from `Dir.pwd`. `Identity::CONFIG_CANDIDATES`
is three relative paths, `SkillRegistry#default_roots` starts at
`./config/riggs/skills`, and `Triggers.find_workflows` globs
`./config/riggs/workflows`. One repo, one config, one database. Riggs cannot
serve a second product without a second copy of everything.

That is the feature problem. The security problem is the one gap #6 names: the
file that arrives with a cloned repository declares users, roles, provider
credentials, and MCP servers with their `command`, `args`, and `env`. The code
that runs and the identity model that authorizes it come from the same
untrusted artifact. RBAC does not help, because RBAC answers "what may this
principal do?" and the missing question is "may this file define principals at
all?"

Both problems have the same fix, and the three tools riggs sits alongside have
already converged on it.

### Prior art, read off the machine rather than inferred

- `~/.codex/config.toml` holds `[mcp_servers.*]` definitions and, separately,
  `[projects."/Users/matt/Projects/zeroclaw"] trust_level = "trusted"` — twelve
  registered absolute paths. Nothing in any repo declares anything.
- `~/.claude/` holds `settings.json` (permissions, model, hooks, plugins) and
  keys per-project state by path slug under `projects/`. The project-local
  `.claude/settings.local.json` in this repo contains exactly one key:
  `permissions`. An override, never a definition.
- `~/.cursor/mcp.json` holds MCP server definitions globally. `cursor-agent`
  refuses to start in an unrecognized directory with "⚠ Workspace Trust
  Required — Do you trust the contents of this directory?"

Four rules are common to all three: definitions are global; trust is a global
registry keyed by absolute path; per-project state is stored globally; and
project-local files carry narrow overrides only. None of them requires a marker
file to make a directory a project — the tool runs anywhere, and trust is
recorded against the path.

## Non-goals

- **Sandboxing.** Trust is an input-loading guard, exactly as Pi's docs are
  careful to describe `project_trust`. An approved MCP server runs with the
  user's full privileges. Nothing here constrains what approved code may do.
- **Credential storage.** No tier gains the ability to hold a secret value.
  Phases 9 and 10 settled that credentials come from the environment or a CLI's
  own stored login; this spec narrows where they may appear, never widens it.
- **Multi-machine sync.** `~/.riggs/` is local. Sharing it is out of scope.
- **Cross-project memory.** Ruled out below; recall never crosses a project.
- **Per-project databases.** One ledger, so cost rolls up across products.

## Decisions

1. **No repo marker.** A directory is a riggs project because you ran riggs in
   it and answered the trust prompt. Nothing committed declares it. This
   matches all three tools and removes an entire class of question — "is riggs
   installed here?" has no answer worth storing, because the honest answer is
   "riggs runs anywhere; this path is trusted or it isn't."

2. **Definition is global, assignment is local.** The global tier says what a
   role means and what a provider is. The project tier says who is here and
   which of those things they use. The one exception is a role name the global
   tier does not define (R11.2).

3. **Trust gates the project tier in its entirety.** An untrusted directory's
   `.riggs/config.yml` is not read — not partially, not for "safe" keys. A
   partial read means maintaining a per-key threat model forever, and the first
   key that gets misclassified is a silent escalation.

4. **Three merge algebras, on purpose.** A lost provider is a billing surprise,
   a lost MCP server is a missing tool, and a lost skill is a silent capability
   change. One algorithm cannot serve all three (R11.2).

5. **No tier holds credentials.** Not global config, not project config, not
   the trust registry.

6. **One ledger, path-keyed.** Cost roll-up across products is the reason the
   database is global, so attribution is not optional — it is the point.

## R11.1 File layout and resolution order

```
~/.riggs/
  config.yml       users, roles, providers, mcp_servers, sqlite_path
  trust.yml        per-path trust and MCP approvals (machine-written)
  skills/
  workflows/
  riggs.sqlite3    one database, every project

<repo>/
  .riggs/config.yml          project tier, committed
  config/riggs/skills/       unchanged
  config/riggs/workflows/    unchanged
  .agent_hubrc               legacy alias for .riggs/config.yml (R11.8)
```

`trust.yml` is a separate file from `config.yml` because riggs rewrites it on
every approval. A hand-authored config file must not churn under the tool.

`~/.riggs/config.yml` and `~/.riggs/trust.yml` are both created `0600`.

**`project_path` is always the absolute current working directory**, resolved
once per invocation, whether or not `.riggs/config.yml` exists there and whether
or not the path is trusted. It is the key for trust, attribution (R11.6), and
memory scoping (R11.7), so it must never be nil — a directory with no project
tier is still a project for the purposes of "whose spend was that" and "which
memories are these."

**`$HOME` is never a project directory.** The project tier lives at
`<project_path>/.riggs/config.yml` and the global tier at
`~/.riggs/config.yml`; when `project_path` is `$HOME` those are the same file,
and reading one file as both tiers makes every R11.2 redefinition check fire
against itself. When `project_path == File.expand_path("~")` there is no
project tier: the global tier is used alone, and `riggs setup` writes no
project file. Attribution and memory scoping still key on the path as normal.

Skills and workflows resolve through an ordered root list, first match wins:

```
<repo>/config/riggs/skills      →  ~/.riggs/skills      →  gem-bundled
<repo>/config/riggs/workflows   →  ~/.riggs/workflows   →  gem-bundled
```

`SkillRegistry#default_roots` is already a two-entry list of exactly this
shape; the global tier is one inserted element. `Triggers.find_workflows` and
`Triggers.list_declared` take a single `dir:` keyword today and must take a
list.

**Shadowing, not merging, for both.** A project `triage.yml` replaces the
global one rather than both appearing. A workflow present only globally is
still available in every project — that is what makes the tier useful — so
`triggers:list` and `triggers:match` MUST report the tier each entry resolved
from. A global workflow carrying a `keyword` trigger fires in every repo, and
an operator who cannot see that will not be able to explain why.

## R11.2 Merge algebra

| key | rule |
| --- | --- |
| `sqlite_path` | Global only. Project tier setting it is a hard error. |
| `roles` | Project may define a role name the global tier does not define. Redefining a global name is a hard error. |
| `users` | Merge by key. Project may add users and may override an existing user's `role`. |
| `default_user` | Project may set it. Must resolve within the merged user set. |
| `providers` | Override only. Project may set `model`, `base_url`, `pricing`, `relay_chain`, `auth` on a globally-defined provider. Naming an undefined provider is a hard error. `api_key` in the project tier is a hard error. |
| `mcp_servers` | Merge by name. Project may add. Every project-supplied server is approval-gated (R11.3). |

Three distinct behaviors — replace-or-error, merge-by-key, merge-with-gate —
and each error message must name the file that lost, not just the key:

```
role 'engineer' is defined in ~/.riggs/config.yml and cannot be redefined
by /Users/matt/Projects/foo/.riggs/config.yml
```

**On `roles` and escalation.** Restricting `roles` does not make the project
tier safe, and the spec should not pretend otherwise. A project tier that can
add a user and set `default_user` can already select a high-privilege identity
using only globally-defined roles. Trust is the boundary; the `roles` rule
exists so that `pm`, `engineer`, and `viewer` keep one fixed meaning across
every repo, which is a legibility property, not a defensive one.

Permissions are free-form strings checked at `lib/riggs/cli/commands.rb:601`
and `lib/riggs/web/app.rb:50`; nothing validates a permission name, so an
unrecognized one silently never matches. That is unchanged here and worth
knowing when reading a role definition.

## R11.3 Trust registry and MCP approval

```yaml
# ~/.riggs/trust.yml
projects:
  /Users/matt/Projects/foo:
    trusted_at: 2026-08-10T14:22:03Z
    mcp_approved:
      honeybadger: "sha256:9f2a…"
```

A timestamp, an absolute path, and a digest. **No value from any environment
variable, argument, or credential is ever written to this file.**

Folder trust is asked once per path, before any project-tier file is read.
Each MCP server is then approved separately before its first spawn. The digest
covers the resolved command array, its arguments, and the **names** of
forwarded environment variables — never their values. A changed command
re-prompts.

The approval prompt prints the command it is asking about, which is a leak path
if a secret was passed in `argv`:

```
⚠ project declares MCP server 'honeybadger'
  command: npx -y hb-mcp --token sk-live-abc123
  approve? [y/N]
```

**The prompt MUST redact any argument that follows a flag matching
`/key|token|secret|password/i`**, and the documentation must direct secrets to
environment variables by name. The heuristic is not airtight; printing an
unredacted `argv` is a guaranteed leak, and this makes the common shape safe.

## R11.4 Non-interactive contexts fail closed

The web UI, triggers, and any scheduled invocation never prompt. An untrusted
path or an unapproved MCP server in those contexts produces an error naming the
command that fixes it:

```
MCP server 'honeybadger' declared by this project is not approved.
Run: riggs mcp:approve honeybadger
```

A prompt nobody can answer is a hang, and auto-approving because nobody is
watching inverts the guarantee.

New commands: `riggs trust` (approve the current directory), `riggs trust:list`,
`riggs mcp:approve <name>`.

## R11.5 Identity provenance is printed

Every run prints the resolved identity and the tier that supplied it:

```
▸ running as eng_bob (engineer) — from .riggs/config.yml
```

Given that a trusted project tier can select an identity, the operator must be
able to see which file chose it. Escalation you can see is a different problem
from escalation you cannot.

`riggs identity:show` reports the same provenance per field.

## R11.6 Attribution

One new column: `riggs_sessions.project_path`, populated at
`Storage#create_session` from the absolute path riggs resolved the project tier
against.

`riggs_provider_calls.session_id` already carries a foreign key to
`riggs_sessions` (`lib/riggs/storage.rb:340`), so every provider call reaches a
project through that join and no second column is needed. Attribution belongs
on the session because a session belongs to exactly one project for its whole
life, while a call belongs to one session — a column on the child table would
duplicate a value that cannot vary and invite the two to disagree.

`Storage#ensure_columns!` already inspects `riggs_sessions` and adds a missing
column; this is a second entry in the same method, on the same table.

New: `riggs cost --by-project`, joining `riggs_provider_calls` to
`riggs_sessions` and grouping on `project_path`.

Rows written before this column exists have `project_path` NULL and MUST be
reported under an explicit `(unattributed)` bucket rather than silently
dropped — a roll-up that omits history is a wrong total, not a partial one.

## R11.7 Memory is project-scoped

Memory never crosses projects. A fact learned building one product does not
surface while building another.

This is achieved by composing the namespace, **not** by adding a column:

```ruby
@namespace = "#{memory_namespace}@#{project_path}"
```

`MemoryService` filters `WHERE m.namespace = ?` (`lib/riggs/memory/service.rb:143`)
and its sqlite-vector backend independently scopes by paths ending
`_by_#{@namespace}` (`:130`). Composition scopes both backends with one change.
A `project_path` column would scope the SQL backend and silently miss the vector
one, which is the failure mode where recall appears to work in tests and leaks
in the field.

Memories written before this change carry an uncomposed namespace and will not
match any project. They are not migrated; `riggs memory:recall` gains a
`--legacy` flag that queries the uncomposed namespace so nothing is stranded.

## R11.8 Back-compat

`.agent_hubrc` has 46 references across nine non-doc files, including
`ConfigStore` and the web UI config editor. It is not removed. It is read as the
**project tier** with a deprecation notice, and `Identity::CONFIG_CANDIDATES`
becomes a tiered resolver rather than a flat list.

`ConfigStore` and `/config` edit the project tier and must display which tier
each value came from, since a value shown without its origin invites an edit
that lands in the wrong file.

`riggs setup` stays one command with no new flags. It ensures both tiers exist,
per artifact, creating only what is missing and never overwriting a config file
that is already there — the behavior `setup` has today, extended across two
tiers.

**Global tier**, checked and created first: `~/.riggs/config.yml`,
`~/.riggs/trust.yml`, `~/.riggs/skills/`, `~/.riggs/workflows/`, and the
database. Each is created only if absent, so a global tier whose `skills/`
directory was deleted is repaired rather than left broken, and an existing
`config.yml` is reported and kept.

**On first creation of the global `config.yml` only**, if the current directory
has an `.agent_hubrc` or `.riggs/config.yml` carrying `users`, `roles`, or
`providers`, setup seeds the global file from them and says so. This is the
upgrade path, and it fires at the one moment the values to import are in reach.
It never runs against an existing global config.

**Project tier**, unless `project_path` is `$HOME` (R11.1): `.riggs/config.yml`
plus the project `skills/` and `workflows/` directories. It no longer writes
`db/`, `sqlite_path`, `users`, or `roles`. The file it writes is a commented
skeleton naming only keys the project tier may set under R11.2, so a generated
file cannot itself trip a hard error.

Running `riggs setup` in a directory **records trust for that path**. Typing it
somewhere you chose is consent, so no separate prompt is raised — but setup MUST
print that it granted trust, alongside which tiers it created and which it found
and kept. A trust grant nobody saw is the thing R11.5 exists to prevent.

## R11.9 Tests

Every claim below must be proved by breaking it and watching a test fail.

1. An untrusted directory's `.riggs/config.yml` is not read — asserted on a
   file whose `mcp_servers` entry would spawn an observable command, proving
   the command never ran, not merely that a hash was empty.
2. A project tier redefining a global role name raises, naming both files.
3. A project tier setting `api_key` raises.
4. A project tier naming an undefined provider raises, listing the defined ones.
5. A project tier adding a user and overriding an existing user's role both
   take effect after trust is granted.
6. Skill and workflow resolution: project shadows global shadows bundled; a
   globally-defined workflow is visible in a project that does not define it;
   `triggers:list` reports the tier.
7. An MCP server whose command changes after approval re-prompts.
8. The approval prompt redacts `--token <value>`; asserted against captured
   output, not against the arguments handed to a formatter.
9. Non-interactive: an unapproved server produces the `riggs mcp:approve` error
   rather than blocking on input.
10. `trust.yml` contains no environment variable value — asserted by writing a
    known sentinel into a forwarded variable and grepping the written file.
11. `project_path` is recorded on new sessions and `riggs cost --by-project`
    groups correctly, with pre-existing NULL rows reported as `(unattributed)`.
12. A memory persisted under project A is not returned by recall under
    project B, on **both** the SQL and vector backends.
13. `riggs setup` run twice leaves an existing `~/.riggs/config.yml` byte-for-byte
    unchanged, while recreating a `~/.riggs/skills/` directory deleted between
    the two runs.
14. `riggs setup` in a directory holding an `.agent_hubrc` with `users` and
    `roles`, against a machine with no `~/.riggs/`, produces a global config
    carrying those users and roles — and the same command run a second time,
    against a different `.agent_hubrc`, does not alter the global file.
15. `riggs setup` with `project_path == $HOME` writes no project tier and does
    not overwrite the global `config.yml` it just created.
16. `riggs setup` records trust for the path and prints that it did.

## What breaks

- Any existing `.agent_hubrc` continues to load, but `sqlite_path`, `users`,
  and `roles` in it now belong to the project tier, where `sqlite_path` and
  `roles` redefinitions are hard errors. The seeding step in R11.8 is what
  keeps the first upgrade from being a manual copy, and it only fires once —
  so the upgrade must be run from a repo that still has the `.agent_hubrc`
  worth importing. Running `riggs setup` first in an empty directory creates
  an empty global tier and forecloses the import; setup MUST say what it
  seeded, or say plainly that it created an empty global config, so this is
  visible when it happens rather than at the next failed run.
- The database moves from `db/riggs.sqlite3` to `~/.riggs/riggs.sqlite3`. An
  explicit `sqlite_path` in the global tier still wins, so an existing database
  can be adopted in place rather than migrated.
- Memory recall returns nothing for pre-existing memories until `--legacy`.
- `ConfigStore` writes gain a tier, which changes its API.

## Open for the implementer

Two choices shape the boundary more than the code around them, and both are the
operator's call rather than the implementer's:

1. **Whether env var names enter the approval digest.** Including them means
   renaming a forwarded variable re-prompts; excluding them means an approved
   server can be pointed at a new secret without re-approval.
2. **Whether an untrusted directory refuses to run at all, or runs with the
   project tier ignored.** The second is friendlier and still safe by
   construction; the first is louder.

## Split

**Phase 11a** — R11.1 through R11.5, R11.8. Config tiers, trust, approval,
provenance, two-tier `setup`.

**Phase 11b** — R11.6, R11.7. Attribution column, cost roll-up, memory scoping.
Small, and depends on 11a landing, because the project path it records is the
one 11a resolves.

## Definition of done

Cloning a repository whose `.riggs/config.yml` declares an MCP server and a
privileged user, then running a riggs command in it, executes no attacker-chosen
command and grants no attacker-chosen role — verified by running it, with the
declared command being one whose execution leaves an observable artifact.

Two product repositories on one machine run riggs against one global identity,
one database, and their own workflows and skills, and `riggs cost --by-project`
reports each product's spend separately.

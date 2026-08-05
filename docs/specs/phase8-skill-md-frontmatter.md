# Phase 8 Spec — Read `SKILL.md` Frontmatter (#7)

Status: approved, not yet implemented
Gaps closed: `docs/gaps.md` #7
Date: 2026-08-05

## Motivation

`SkillRegistry` loads a skill only from `config/riggs/skills/<name>/SKILL.yml`.
`SKILL.md` — YAML frontmatter plus a markdown body — is becoming the
cross-harness convention, and Riggs cannot read a single file from that
ecosystem.

The fix is small because `SkillRegistry#read_skill_dir` is a genuine choke
point: one method turns a directory into a hash, and every other method in the
class consumes only that hash. Supporting a second container means branching in
one place, not threading a new concept through the registry.

Riggs pins a skill per step rather than letting a model choose one, so only the
file format has to interoperate. Discovery semantics are out of scope.

## Non-goals

- Reading `./.agents/skills/` or `~/.agents/skills/`. The roots stay exactly as
  they are. The repo-local root in particular would let a cloned repository
  supply text that becomes a system prompt — the same class of exposure as
  gap #6, which is still open.
- Model-driven skill selection. `description` exists in the format so a model
  can pick a skill; Riggs pins skills per step and does not need that.
- Sending `description` to the model. It is metadata about the skill, not
  instructions, and rewriting it into the prompt would change what the author
  wrote.
- A `SKILL.md` *writer*. Riggs reads the format; it does not emit it.

## Decisions

Recorded with their reasoning so they do not get relitigated.

1. **Format only, not discovery.** An off-the-shelf `SKILL.md` drops into the
   roots Riggs already scans. The *file* needs no edits, which is what the gap's
   "done when" asks for.
2. **`SKILL.md` frontmatter uses the same key space as `SKILL.yml`.** `version`,
   `tools`, and `mcp_servers` are honored there if present. A file carrying only
   `name` and `description` still loads and simply has no tools. This is less
   code than a restricted parser, not more, because it reuses the existing
   normalization path — and it means adding one tool to an imported skill does
   not force a conversion to `SKILL.yml`.
3. **`description` joins the skill shape.** Without it, the one line of
   human-readable self-description the format carries would be parsed and
   thrown away.
4. **`SKILL.yml` wins when both exist, silently.** No existing skill changes
   behavior on upgrade. This matches the registry's existing rule that an
   explicit `system_prompt:` key beats a `prompt.md` file.

## R7.1 `Riggs::SkillFrontmatter`

New file `lib/riggs/skills/frontmatter.rb`, required by
`lib/riggs/skills/registry.rb` (not by `lib/riggs.rb` — the registry is its only
consumer).

The name is `Riggs::SkillFrontmatter`, not `Riggs::Skills::Frontmatter`:
`lib/riggs/skills/registry.rb` already defines `Riggs::SkillRegistry`, so path
does not imply namespace in this directory, and matching that beats introducing
a second convention.

One public method, pure — it takes a String and touches no files:

```ruby
Riggs::SkillFrontmatter.parse(text) # => { data: Hash, body: String }
```

Parsing rules, in order:

1. A leading UTF-8 BOM is stripped before anything else. These files come from
   other people's repositories.
2. Line endings are normalized so CRLF documents parse identically to LF ones.
   Same reason.
3. If the first line is not exactly `---` (trailing whitespace allowed), there
   is no frontmatter: return `{ data: {}, body: <entire text> }`.
4. Otherwise the frontmatter runs to the **first** subsequent line that is
   exactly `---`. Only the first closing delimiter counts, so a `---`
   horizontal rule later in the body stays body text.
5. If no closing delimiter is ever found, treat the document as having no
   frontmatter (rule 3). A file that opens a block and never closes it is more
   likely a document starting with a horizontal rule than a truncated header,
   and this is how frontmatter parsers generally behave.
6. The frontmatter is parsed with
   `Psych.safe_load(..., permitted_classes: [Symbol], aliases: true)`, matching
   the call the registry already makes. An empty block yields `{}`.
7. YAML that parses to something other than a Hash or nil raises
   `ArgumentError`. A list or bare string where a mapping belongs is malformed,
   not an empty header.
8. `body` is everything after the closing delimiter line, minus the single
   newline that terminates that line. It is returned verbatim otherwise —
   leading blank lines and trailing whitespace are the author's.

## R7.2 The registry reads either container

`SkillRegistry#read_skill_dir` currently returns `nil` unless `SKILL.yml`
exists. It becomes:

- `SKILL.yml` present → parse as today. `body` is `nil`.
- Else `SKILL.md` present → `SkillFrontmatter.parse`, giving `data` and `body`.
- Else `nil`, as today.

Everything downstream is untouched. `normalize_tools`, the version fallback
chain (`data[:version]` → `name@version` directory → `"0.1.0"`), the name
fallback (`data[:name]` → directory name before `@`), `find_candidates`,
`list`, and `load` all consume the same hash they do now, so version pinning
(`triage_v1@1.0.0`) and multi-version directories work for `SKILL.md` skills
with no additional code.

The system-prompt fallback chain gains one link, keeping its existing ordering
(explicit key beats file):

1. `data[:system_prompt]`, if present and non-empty
2. the markdown body, if this was a `SKILL.md`
3. `prompt.md` in the same directory

## R7.3 `description` in the skill shape

`read_skill_dir` and `format_skill` carry `description`, defaulting to `""`.
Because R7.1 gives both containers one key space, a `SKILL.yml` may declare
`description:` too.

Surfaces:

- `riggs skills:show NAME` prints the description under the header when it is
  non-empty.
- `riggs skills:list` appends ` — <description>` to a skill's line when it is
  non-empty.
- The web Skills table gains a Description column.

`SkillRegistry#list` groups by name across versions and reports the **newest**
version's description, matching how it already reports `latest`.

## R7.4 Precedence

A directory holding both files loads `SKILL.yml`. No warning, no event: adding
`SKILL.md` support must not change how any skill that exists today behaves.

## R7.5 A malformed skill file is skipped, not fatal

`read_skill_dir` rescues per directory, naming the classes it expects —
`Psych::SyntaxError` (malformed YAML), `ArgumentError` (R7.1 rule 7), and
`SystemCallError` (unreadable file). Not a blanket `StandardError`: a rescue
that wide turns a genuine bug in the registry into "that skill doesn't exist",
which is the failure mode Phase 7's review found hiding a real defect in
`Compactor#call_router`.

A file that fails to parse is skipped, the other skills still load, and one
warning names the path and the error:

```
riggs: skipping skill at config/riggs/skills/broken (Psych::SyntaxError: ...)
```

The existing `next unless data` guards in `find_candidates` and `list` already
handle a `nil` return, so no caller changes.

**This applies to `SKILL.yml` as well, which is a behavior change beyond the
gap's letter.** Today a malformed `SKILL.yml` raises out of `list` and takes
down every command that touches the registry, including runs that only wanted a
different skill. Handling the two containers differently would be the strange
outcome, and the failure mode is the one Phase 7 already ruled on for malformed
provider payloads: a bad bookkeeping input must not take the run down.

## R7.6 Tests

Parser unit:

- a standard document splits into frontmatter and body
- a document with no leading `---` is all body, `data` is `{}`
- an empty frontmatter block yields `{}` and the body
- a `---` horizontal rule in the body stays in the body
- an unterminated opening delimiter is treated as no frontmatter
- CRLF input parses identically to LF
- a leading BOM does not defeat delimiter detection
- non-mapping YAML raises `ArgumentError`

Registry integration:

- a `SKILL.md` skill loads, with the markdown body as `system_prompt`
- `description` reaches the loaded skill
- `tools:` declared in `SKILL.md` frontmatter produce real tools, with the same
  normalization `SKILL.yml` tools get
- `version:` in frontmatter pins (`name@version` resolves)
- a directory with both files loads the `SKILL.yml`
- a malformed skill file is skipped while a sibling skill still loads, and the
  warning names it
- `list` includes `SKILL.md` skills and carries the latest version's description

Definition-of-done fixture: a realistic off-the-shelf `SKILL.md` carrying only
`name` and `description` in frontmatter, copied in unmodified, loads and drives
a workflow step.

## Definition of done

An off-the-shelf `SKILL.md` — frontmatter with `name` and `description`,
instructions in the body, nothing Riggs-specific — is placed in
`config/riggs/skills/<name>/` without edits, is named by a workflow step, and
that step runs with the body as its system prompt.

# SKILL.md Frontmatter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `SkillRegistry` loads a skill from `SKILL.md` (YAML frontmatter + markdown body) as well as `SKILL.yml`, so an off-the-shelf skill file drops into a workflow step unmodified.

**Architecture:** One new pure parser (`Riggs::SkillFrontmatter.parse`) splits a document into frontmatter and body. `SkillRegistry#read_skill_dir` — the single method that turns a directory into a hash — gains a branch choosing the container. Every other method in the registry consumes the same hash it does today, so version pinning, `find_candidates`, `list`, and `load` need no changes.

**Tech Stack:** Ruby 4.0, Psych (already a dependency), Minitest, RuboCop.

## Global Constraints

Copied from `docs/specs/phase8-skill-md-frontmatter.md`. Every task's requirements implicitly include these.

- **No new discovery roots.** `default_roots` is not touched. Do not add `./.agents/skills/` or `~/.agents/skills/`.
- **`SKILL.yml` wins when both files exist, silently.** No warning, no audit event. No skill that exists today may change behavior.
- **`SKILL.md` frontmatter uses the same key space as `SKILL.yml`** — `name`, `version`, `description`, `system_prompt`, `tools`, `mcp_servers` all mean the same thing in both containers.
- **`description` never reaches the model.** It is metadata for `skills:show`, `skills:list`, and the web table only. Do not append it to `system_prompt`.
- **The malformed-file rescue names its classes:** `Psych::SyntaxError`, `ArgumentError`, `SystemCallError`. Never `rescue StandardError` in `read_skill_dir` — a rescue that wide turns a registry bug into "that skill doesn't exist".
- **YAML is loaded with `Psych.safe_load(..., permitted_classes: [Symbol], aliases: true)`**, matching the call the registry already makes.
- Ruby 4.0. RuboCop must pass (`bundle exec rubocop`); the repo's pre-commit hook runs RuboCop and the full suite on every commit, so a commit that fails either is rejected automatically.
- Run the full suite with `bundle exec rake test`. A single file: `bundle exec ruby -Ilib -Itest test/test_foo.rb`.

## File Structure

| File | Responsibility |
|---|---|
| `lib/riggs/skills/frontmatter.rb` | **Create.** `Riggs::SkillFrontmatter.parse(text)` → `{data:, body:}`. Pure string function, no file IO. |
| `lib/riggs/skills/registry.rb` | **Modify.** `read_skill_dir` picks a container; new private `skill_source`, `resolve_prompt`, `sortable_version`. `format_skill` and `list` carry `description`. |
| `lib/riggs/cli/commands.rb` | **Modify.** `skills_show` and `skills_list` display `description`. |
| `lib/riggs/web/views/skills.erb` | **Modify.** Description column. |
| `test/test_skill_frontmatter.rb` | **Create.** Parser unit tests. |
| `test/test_skills.rb` | **Modify.** Registry integration tests. |
| `README.md`, `CHANGELOG.md`, `docs/gaps.md` | **Modify.** Document the format; strike gap #7. |

Note on naming: the new module is `Riggs::SkillFrontmatter`, **not** `Riggs::Skills::Frontmatter`. `lib/riggs/skills/registry.rb` already defines `Riggs::SkillRegistry`, so path does not imply namespace in this directory. Match the existing convention.

---

### Task 1: The frontmatter parser

**Files:**
- Create: `lib/riggs/skills/frontmatter.rb`
- Test: `test/test_skill_frontmatter.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Riggs::SkillFrontmatter.parse(text) → { data: Hash, body: String }`. `data` has **string** keys (the registry symbolizes later). Raises `ArgumentError` when the frontmatter parses to something other than a Hash or nil.

- [ ] **Step 1: Write the failing tests**

Create `test/test_skill_frontmatter.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class TestSkillFrontmatter < Minitest::Test
  def test_splits_frontmatter_from_body
    text = "---\nname: writer\ndescription: Writes things\n---\nDo the thing.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "writer", result[:data]["name"]
    assert_equal "Writes things", result[:data]["description"]
    assert_equal "Do the thing.\n", result[:body]
  end

  def test_a_document_without_frontmatter_is_all_body
    text = "# Just markdown\n\nNo header here.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_empty result[:data]
    assert_equal text, result[:body]
  end

  def test_an_empty_frontmatter_block_yields_an_empty_hash
    text = "---\n---\nBody text.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_empty result[:data]
    assert_equal "Body text.\n", result[:body]
  end

  # Markdown uses --- for horizontal rules. Only the FIRST closing delimiter
  # ends the frontmatter; everything after it is body, rules included.
  def test_a_horizontal_rule_in_the_body_stays_in_the_body
    text = "---\nname: writer\n---\nIntro.\n\n---\n\nMore prose.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "writer", result[:data]["name"]
    assert_includes result[:body], "---"
    assert_includes result[:body], "More prose."
  end

  # A document that opens a block and never closes it is far more likely to be
  # prose starting with a horizontal rule than a truncated header.
  def test_an_unterminated_opening_delimiter_is_treated_as_no_frontmatter
    text = "---\nthis never closes\nand keeps going\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_empty result[:data]
    assert_equal text, result[:body]
  end

  # These files come from other people's repositories.
  def test_crlf_input_parses_identically_to_lf
    crlf = "---\r\nname: writer\r\n---\r\nDo the thing.\r\n"

    result = Riggs::SkillFrontmatter.parse(crlf)

    assert_equal "writer", result[:data]["name"]
    assert_equal "Do the thing.\n", result[:body]
  end

  def test_a_leading_byte_order_mark_does_not_defeat_delimiter_detection
    text = "﻿---\nname: writer\n---\nBody.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "writer", result[:data]["name"]
    assert_equal "Body.\n", result[:body]
  end

  def test_non_mapping_frontmatter_raises
    text = "---\n- one\n- two\n---\nBody.\n"

    assert_raises(ArgumentError) { Riggs::SkillFrontmatter.parse(text) }
  end

  def test_malformed_yaml_raises_psych_syntax_error
    text = "---\nname: [unclosed\n---\nBody.\n"

    assert_raises(Psych::SyntaxError) { Riggs::SkillFrontmatter.parse(text) }
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_skill_frontmatter.rb`

Expected: every test errors with `NameError: uninitialized constant Riggs::SkillFrontmatter`.

- [ ] **Step 3: Write the implementation**

Create `lib/riggs/skills/frontmatter.rb`:

```ruby
# frozen_string_literal: true

require "psych"

module Riggs
  # Splits a SKILL.md into its YAML frontmatter and its markdown body.
  #
  # Pure by design: it takes a String and touches no files, so the registry
  # keeps sole ownership of file IO and this stays trivially testable.
  #
  # Returns string-keyed data. The registry symbolizes, exactly as it does for
  # SKILL.yml, so both containers converge on one shape.
  module SkillFrontmatter
    DELIMITER = /\A---[ \t]*\z/
    BOM = "﻿"

    def self.parse(text)
      source = normalize(text)
      lines = source.lines
      return { data: {}, body: source } unless delimiter?(lines.first)

      close = (1...lines.length).find { |i| delimiter?(lines[i]) }
      # An opening delimiter with no closing one: treat the whole document as
      # body rather than as a broken header.
      return { data: {}, body: source } if close.nil?

      { data: load_yaml(lines[1...close].join),
        body: Array(lines[(close + 1)..]).join }
    end

    # A BOM would make the first line "﻿---" and defeat delimiter
    # detection; CRLF would leave "\r" on every chomp-less comparison. Both
    # arrive routinely from other people's repositories.
    def self.normalize(text)
      text.to_s.delete_prefix(BOM).gsub("\r\n", "\n")
    end

    def self.delimiter?(line)
      !line.nil? && DELIMITER.match?(line.chomp)
    end

    def self.load_yaml(yaml)
      raw = Psych.safe_load(yaml, permitted_classes: [Symbol], aliases: true)
      return {} if raw.nil?
      raise ArgumentError, "SKILL.md frontmatter must be a mapping, got #{raw.class}" unless raw.is_a?(Hash)

      raw
    end

    private_class_method :normalize, :delimiter?, :load_yaml
  end
end
```

Then add the require to `lib/riggs/skills/registry.rb`, immediately below its existing `require "psych"`:

```ruby
require_relative "frontmatter"
```

The registry is this module's only consumer, so it does not belong in `lib/riggs.rb`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/test_skill_frontmatter.rb`

Expected: 9 runs, 0 failures.

- [ ] **Step 5: Verify the mutation is caught**

Temporarily change `close = (1...lines.length).find { ... }` to `close = (1...lines.length).to_a.reverse.find { ... }` (last delimiter instead of first) and re-run. Expected: `test_a_horizontal_rule_in_the_body_stays_in_the_body` fails. Revert.

- [ ] **Step 6: Run RuboCop and the full suite**

Run: `bundle exec rubocop && bundle exec rake test`
Expected: no offenses; 274 runs, 0 failures (265 existing + 9 new).

- [ ] **Step 7: Commit**

```bash
git add lib/riggs/skills/frontmatter.rb lib/riggs/skills/registry.rb test/test_skill_frontmatter.rb
git commit -m "Add SKILL.md frontmatter parser"
```

---

### Task 2: The registry reads either container

**Files:**
- Modify: `lib/riggs/skills/registry.rb:89-110` (`read_skill_dir`)
- Test: `test/test_skills.rb`

**Interfaces:**
- Consumes: `Riggs::SkillFrontmatter.parse(text) → { data: Hash, body: String }` from Task 1.
- Produces: `read_skill_dir` returns the same hash shape as today (`name`, `version`, `system_prompt`, `tools`, `mcp_servers`, `path`) from either container. Task 3 adds `description` to it.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_skills.rb`, inside the class:

```ruby
  def write_skill_md(dir, contents)
    FileUtils.mkdir_p("config/riggs/skills/#{dir}")
    File.write("config/riggs/skills/#{dir}/SKILL.md", contents)
  end

  def registry
    Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
  end

  def test_loads_a_skill_from_skill_md_with_the_body_as_the_prompt
    with_tmp_project do
      write_skill_md("writer", "---\nname: writer\n---\nWrite clearly. Cite sources.\n")

      skill = registry.load("writer")

      refute_nil skill, "a SKILL.md directory must be discoverable"
      assert_equal "Write clearly. Cite sources.\n", skill[:system_prompt]
    end
  end

  # Same key space in both containers: an imported skill can gain a tool
  # without being converted to SKILL.yml.
  def test_tools_declared_in_skill_md_frontmatter_are_normalized
    with_tmp_project do
      write_skill_md("searcher", <<~MD)
        ---
        name: searcher
        tools:
          - name: search_issues
            description: Search known issues.
            mcp_server: github
            input_schema:
              type: object
              properties:
                query:
                  type: string
        ---
        Search before answering.
      MD

      tool = registry.load("searcher")[:tools].first

      assert_equal "search_issues", tool[:name]
      assert_equal "github", tool[:mcp_server]
      assert_equal "object", tool[:input_schema][:type]
    end
  end

  def test_a_version_in_skill_md_frontmatter_can_be_pinned
    with_tmp_project do
      write_skill_md("pinned", "---\nname: pinned\nversion: \"2.1.0\"\n---\nBody.\n")

      assert_equal "2.1.0", registry.load("pinned")[:version]
      assert_equal "2.1.0", registry.load("pinned@2.1.0")[:version]
      assert_nil registry.load("pinned@9.9.9")
    end
  end

  def test_a_skill_md_without_a_name_falls_back_to_its_directory
    with_tmp_project do
      write_skill_md("unnamed", "---\ndescription: No name key.\n---\nBody.\n")

      assert_equal "unnamed", registry.load("unnamed")[:name]
    end
  end

  # Adding SKILL.md support must not change how any skill that exists today
  # behaves, so the native container wins and nothing is announced.
  def test_skill_yml_wins_when_both_files_exist
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/both")
      File.write("config/riggs/skills/both/SKILL.yml", "name: both\nsystem_prompt: from yml\n")
      File.write("config/riggs/skills/both/SKILL.md", "---\nname: both\n---\nfrom md\n")

      assert_equal "from yml", registry.load("both")[:system_prompt]
    end
  end

  # The existing rule -- an explicit key beats a file -- is preserved, with the
  # markdown body slotted in between the key and prompt.md.
  def test_an_explicit_system_prompt_key_beats_the_markdown_body
    with_tmp_project do
      write_skill_md("explicit", "---\nname: explicit\nsystem_prompt: from key\n---\nfrom body\n")

      assert_equal "from key", registry.load("explicit")[:system_prompt]
    end
  end

  def test_a_skill_md_with_an_empty_body_falls_back_to_prompt_md
    with_tmp_project do
      write_skill_md("fallback", "---\nname: fallback\n---\n")
      File.write("config/riggs/skills/fallback/prompt.md", "from prompt.md")

      assert_equal "from prompt.md", registry.load("fallback")[:system_prompt]
    end
  end

  def test_list_includes_skill_md_bundles
    with_tmp_project do
      write_skill_md("writer", "---\nname: writer\n---\nBody.\n")

      assert_includes registry.list_names, "writer"
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`

Expected: the new tests fail. `test_loads_a_skill_from_skill_md_with_the_body_as_the_prompt` fails on `refute_nil` — `read_skill_dir` returns `nil` because there is no `SKILL.yml`.

- [ ] **Step 3: Write the implementation**

In `lib/riggs/skills/registry.rb`, replace `read_skill_dir` (currently lines 89-110) with:

```ruby
    def read_skill_dir(dir, entry)
      source = skill_source(dir)
      return nil unless source

      data = Identity.deep_symbolize(source[:data])
      version = (data[:version] || version_from_dirname(entry) || "0.1.0").to_s
      name = (data[:name] || entry.split("@").first).to_s

      {
        name: name,
        version: version,
        system_prompt: resolve_prompt(dir, data, source[:body]),
        tools: normalize_tools(Array(data[:tools])),
        mcp_servers: Array(data[:mcp_servers]).map(&:to_s),
        path: dir
      }
    end

    # SKILL.yml wins when both exist. Adding SKILL.md support must not change
    # how a skill that already ships behaves, so the native container takes
    # precedence and nothing is announced about the one that lost.
    def skill_source(dir)
      yml = File.join(dir, "SKILL.yml")
      if File.exist?(yml)
        raw = Psych.safe_load(File.read(yml), permitted_classes: [Symbol], aliases: true) || {}
        return { data: raw, body: nil }
      end

      md = File.join(dir, "SKILL.md")
      return nil unless File.exist?(md)

      SkillFrontmatter.parse(File.read(md))
    end

    # Explicit key beats a file -- the rule SKILL.yml already followed with
    # prompt.md. The markdown body slots in between: it is the natural home for
    # a SKILL.md's instructions, but an author who writes system_prompt: in
    # frontmatter has said something more specific.
    def resolve_prompt(dir, data, body)
      explicit = data[:system_prompt]
      return explicit.to_s unless explicit.nil? || explicit.to_s.empty?
      return body.to_s unless body.nil? || body.to_s.strip.empty?

      prompt_file = File.join(dir, "prompt.md")
      File.exist?(prompt_file) ? File.read(prompt_file) : ""
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`
Expected: all pass, including the two pre-existing tests.

- [ ] **Step 5: Verify the precedence test is not vacuous**

Temporarily reorder `skill_source` so the `SKILL.md` branch is checked first. Re-run. Expected: `test_skill_yml_wins_when_both_files_exist` fails with `"from md"`. Revert.

- [ ] **Step 6: Run RuboCop and the full suite**

Run: `bundle exec rubocop && bundle exec rake test`
Expected: no offenses; 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/riggs/skills/registry.rb test/test_skills.rb
git commit -m "Load skills from SKILL.md as well as SKILL.yml"
```

---

### Task 3: `description` in the skill shape

**Files:**
- Modify: `lib/riggs/skills/registry.rb` (`read_skill_dir`, `format_skill`, `list`)
- Test: `test/test_skills.rb`

**Interfaces:**
- Consumes: `read_skill_dir` from Task 2.
- Produces: `load(name)` returns a hash with `description` (String, `""` when absent). `list` returns `{ name:, versions:, latest:, description: }` where `description` belongs to the **newest** version. Task 5 renders both.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_skills.rb`, inside the class:

```ruby
  def test_description_reaches_the_loaded_skill
    with_tmp_project do
      write_skill_md("writer", "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      assert_equal "Writes clearly.", registry.load("writer")[:description]
    end
  end

  # One key space in two containers: description works in SKILL.yml too.
  def test_description_works_in_skill_yml_as_well
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/ymldesc")
      File.write("config/riggs/skills/ymldesc/SKILL.yml", "name: ymldesc\ndescription: From yaml.\nsystem_prompt: x\n")

      assert_equal "From yaml.", registry.load("ymldesc")[:description]
    end
  end

  def test_a_skill_without_a_description_reports_an_empty_string
    with_tmp_project do
      write_skill_md("plain", "---\nname: plain\n---\nBody.\n")

      assert_equal "", registry.load("plain")[:description]
    end
  end

  # list groups by name across versions; the description shown must be the one
  # belonging to the version list also reports as `latest`.
  def test_list_reports_the_newest_versions_description
    with_tmp_project do
      write_skill_md("multi@1.0.0", "---\nname: multi\nversion: \"1.0.0\"\ndescription: old one\n---\nB.\n")
      write_skill_md("multi@2.0.0", "---\nname: multi\nversion: \"2.0.0\"\ndescription: new one\n---\nB.\n")

      row = registry.list.find { |s| s[:name] == "multi" }

      assert_equal "2.0.0", row[:latest]
      assert_equal "new one", row[:description]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`
Expected: the four new tests fail — `description` is `nil`, not a String.

- [ ] **Step 3: Write the implementation**

In `read_skill_dir`, add the key to the returned hash (after `version:`):

```ruby
        description: (data[:description] || "").to_s,
```

In `format_skill`, add the same key:

```ruby
    def format_skill(data)
      {
        name: data[:name],
        version: data[:version],
        description: data[:description],
        system_prompt: data[:system_prompt],
        tools: data[:tools],
        mcp_servers: data[:mcp_servers]
      }
    end
```

Replace `list` with a version that carries the description alongside each version, and extract the version-sorting rescue that `list` already used inline so both places share it:

```ruby
    def list
      by_name = Hash.new { |h, k| h[k] = [] }
      each_skill_dir do |dir, entry|
        data = read_skill_dir(dir, entry)
        next unless data

        by_name[data[:name]] << { version: data[:version], description: data[:description] }
      end
      by_name.keys.sort.map { |name| summarize(name, by_name[name]) }
    end

    # The description reported for a name must belong to the same version
    # reported as `latest`, or the table describes one skill and versions
    # another.
    def summarize(name, entries)
      ordered = entries.uniq { |e| e[:version] }.sort_by { |e| sortable_version(e[:version]) }
      newest = ordered.last
      { name: name, versions: ordered.map { |e| e[:version] },
        latest: newest&.fetch(:version), description: newest ? newest[:description] : "" }
    end

    def sortable_version(ver)
      Gem::Version.new(normalize_version(ver))
    rescue StandardError
      Gem::Version.new("0")
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`
Expected: all pass, including `test_list_includes_versions` from before this plan.

- [ ] **Step 5: Verify the newest-version test is not vacuous**

Temporarily change `newest = ordered.last` to `newest = ordered.first`. Re-run. Expected: `test_list_reports_the_newest_versions_description` fails with `"old one"`. Revert.

- [ ] **Step 6: Run RuboCop and the full suite**

Run: `bundle exec rubocop && bundle exec rake test`
Expected: no offenses; 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/riggs/skills/registry.rb test/test_skills.rb
git commit -m "Carry skill description through the registry"
```

---

### Task 4: A malformed skill file is skipped, not fatal

**Files:**
- Modify: `lib/riggs/skills/registry.rb` (`read_skill_dir`)
- Test: `test/test_skills.rb`

**Interfaces:**
- Consumes: `read_skill_dir` from Tasks 2-3.
- Produces: `read_skill_dir` returns `nil` and warns instead of raising, for `Psych::SyntaxError`, `ArgumentError`, and `SystemCallError`. Callers already guard with `next unless data`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_skills.rb`, inside the class:

```ruby
  # One bad directory -- often imported from someone else's repository --
  # must not take down every command that touches the registry.
  def test_a_malformed_skill_md_is_skipped_and_its_neighbour_still_loads
    with_tmp_project do
      write_skill_md("broken", "---\nname: [unclosed\n---\nBody.\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      out = capture_io { names = registry.list_names }.join

      assert_includes names, "healthy"
      refute_includes names, "broken"
      assert_match(/skipping skill/, out)
      assert_match(%r{config/riggs/skills/broken}, out)
    end
  end

  def test_a_malformed_skill_md_does_not_break_loading_another_skill
    with_tmp_project do
      write_skill_md("broken", "---\nname: [unclosed\n---\nBody.\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nGood body.\n")

      skill = nil
      capture_io { skill = registry.load("healthy") }

      refute_nil skill
      assert_equal "Good body.\n", skill[:system_prompt]
    end
  end

  # Non-mapping frontmatter raises ArgumentError from the parser; that is a
  # malformed file, not a crash.
  def test_a_skill_md_with_non_mapping_frontmatter_is_skipped
    with_tmp_project do
      write_skill_md("listy", "---\n- one\n- two\n---\nBody.\n")

      names = nil
      capture_io { names = registry.list_names }

      refute_includes names, "listy"
    end
  end

  # The same posture applies to the native container. Today a malformed
  # SKILL.yml raises out of #list and takes down every command that touches
  # the registry, including runs that wanted a different skill entirely.
  def test_a_malformed_skill_yml_is_skipped_too
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/badyml")
      File.write("config/riggs/skills/badyml/SKILL.yml", "name: [unclosed\n")

      names = nil
      capture_io { names = registry.list_names }

      assert_includes names, "triage_v1", "the bundled skill must still load"
      refute_includes names, "badyml"
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`
Expected: all four error with `Psych::SyntaxError` (or `ArgumentError` for the non-mapping one) escaping `list_names`.

- [ ] **Step 3: Write the implementation**

Add a rescue to `read_skill_dir`, naming the classes. Do **not** use `rescue StandardError`:

```ruby
    def read_skill_dir(dir, entry)
      source = skill_source(dir)
      return nil unless source

      # ... unchanged body ...
    rescue Psych::SyntaxError, ArgumentError, SystemCallError => e
      # Named classes, not StandardError: a rescue that wide would turn a
      # genuine bug in this registry into "that skill doesn't exist", which is
      # the failure mode Phase 7's review found hiding a real defect in
      # Compactor#call_router.
      warn "riggs: skipping skill at #{dir} (#{e.class}: #{e.message.to_s[0, 200]})"
      nil
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`
Expected: all pass.

- [ ] **Step 5: Verify the rescue is not swallowing too much**

Confirm `rescue StandardError` was not used: `grep -n "rescue" lib/riggs/skills/registry.rb`. The `read_skill_dir` rescue must name the three classes. (`sortable_version` and `load` have their own pre-existing rescues; leave them.)

- [ ] **Step 6: Run RuboCop and the full suite**

Run: `bundle exec rubocop && bundle exec rake test`
Expected: no offenses; 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/riggs/skills/registry.rb test/test_skills.rb
git commit -m "Skip a malformed skill file instead of raising"
```

---

### Task 5: Surface the description

**Files:**
- Modify: `lib/riggs/cli/commands.rb` (`skills_list` ~line 471, `skills_show` ~line 483)
- Modify: `lib/riggs/web/views/skills.erb`
- Test: `test/test_cli.rb`, `test/test_web_app.rb`

**Interfaces:**
- Consumes: `load(name)[:description]` and `list` rows carrying `description`, from Task 3.
- Produces: no new interfaces.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_cli.rb`, inside the class:

```ruby
  def test_skills_show_prints_the_description
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/writer")
      File.write("config/riggs/skills/writer/SKILL.md",
                 "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      out = capture_io { Riggs::CLI::Commands.start(%w[skills:show writer]) }.first

      assert_match(/Writes clearly\./, out)
    end
  end

  def test_skills_list_prints_the_description
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/writer")
      File.write("config/riggs/skills/writer/SKILL.md",
                 "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      out = capture_io { Riggs::CLI::Commands.start(%w[skills:list]) }.first

      assert_match(/writer/, out)
      assert_match(/Writes clearly\./, out)
    end
  end
```

Append to `test/test_web_app.rb`, inside the class. That file uses `Rack::Test::Methods`, so requests go through `get` and assertions read `last_response`, and every test sets an identity header first:

```ruby
  def test_skills_page_shows_the_description
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/writer")
      File.write("config/riggs/skills/writer/SKILL.md",
                 "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      header "X-Riggs-User", "eng_bob"
      get "/skills"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Writes clearly."
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_cli.rb && bundle exec ruby -Ilib -Itest test/test_web_app.rb`
Expected: the three new tests fail — the description is never printed.

- [ ] **Step 3: Write the implementation**

In `skills_show`, after the `print_header` line, add:

```ruby
      puts skill[:description] unless skill[:description].to_s.empty?
```

In `skills_list`, replace the `list.each` line with:

```ruby
        list.each do |s|
          line = "• #{s[:name]} (latest #{s[:latest]}; versions: #{s[:versions].join(', ')})"
          line += " — #{s[:description]}" unless s[:description].to_s.empty?
          puts line
        end
```

In `lib/riggs/web/views/skills.erb`, add the column to both the header and the row:

```erb
      <thead><tr><th>Name</th><th>Versions</th><th>Latest</th><th>Description</th></tr></thead>
```

```erb
            <td><%= h((sk[:latest] || sk['latest']).to_s) %></td>
            <td><%= h((sk[:description] || sk['description']).to_s) %></td>
```

The `h()` call is required — descriptions come from files Riggs did not author, and every other cell in this table is escaped the same way.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/test_cli.rb && bundle exec ruby -Ilib -Itest test/test_web_app.rb`
Expected: all pass.

- [ ] **Step 5: Run RuboCop and the full suite**

Run: `bundle exec rubocop && bundle exec rake test`
Expected: no offenses; 0 failures. If RuboCop flags `Style/StringConcatenation` on `line +=`, use string interpolation into a new variable rather than disabling the cop.

- [ ] **Step 6: Commit**

```bash
git add lib/riggs/cli/commands.rb lib/riggs/web/views/skills.erb test/test_cli.rb test/test_web_app.rb
git commit -m "Show skill descriptions in the CLI and web UI"
```

---

### Task 6: Definition of done, and documentation

**Files:**
- Test: `test/test_skills.rb`
- Modify: `README.md`, `CHANGELOG.md`, `docs/gaps.md`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: nothing.

- [ ] **Step 1: Write the failing end-to-end test**

This is the spec's Definition of Done: a file with nothing Riggs-specific in it, unmodified, driving a real step. Append to `test/test_skills.rb`, inside the class:

```ruby
  # The whole point of the feature: a file written for another harness, with no
  # Riggs-specific keys, copied in and used verbatim. Asserting on the system
  # prompt the PROVIDER received proves the body actually reached the model,
  # rather than merely that the registry parsed something.
  def test_an_off_the_shelf_skill_md_drives_a_workflow_step_unmodified
    with_tmp_project do
      write_skill_md("code-reviewer", <<~MD)
        ---
        name: code-reviewer
        description: Reviews a diff for correctness and clarity.
        ---
        # Code Reviewer

        Review the diff. Report correctness problems before style ones.

        ---

        Always name the file and line.
      MD

      captured = []
      capturing = Class.new(Riggs::Providers::Base) do
        define_method(:complete) do |system: nil, **|
          captured << system.to_s
          { provider: name, model: nil, content: "reviewed", tool_calls: [], usage: {} }
        end
      end
      router = Riggs::Providers::Router.new(
        hub_providers: { cap: { type: "cap" } }, registry: { "cap" => capturing }
      )

      workflow = {
        name: "review_flow",
        context_window: 32_000, reserve_tokens: 16_384, keep_recent_tokens: 20_000,
        max_llm_calls: 5, timeout_seconds: 60,
        providers: { default: { relay_chain: ["cap"] } },
        steps: [Riggs::Workflow::StepNode.from_hash(
          "id" => "review", "input" => "Review this.", "output_var" => "review",
          "skill" => "code-reviewer"
        )]
      }
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: { id: "eng_bob", memory_namespace: "eng_bob_private" },
        db_path: "./db/riggs.sqlite3",
        provider_router: router,
        skill_registry: registry
      )

      engine.execute(StringIO.new, input: {})

      assert_equal :completed, engine.status
      assert_includes captured.first, "Report correctness problems before style ones.",
                      "the markdown body must reach the model as the step's system prompt"
      assert_includes captured.first, "Always name the file and line.",
                      "content after a horizontal rule is body, not a second frontmatter block"
    end
  end
```

Add `require "stringio"` to the top of `test/test_skills.rb` if it is not already there.

The keyword is `provider_router:` — `GraphEngine.new(workflow:, user_identity:, storage: nil, db_path: nil, hub_config: {}, gate_handler: nil, provider_router: nil, skill_registry: nil, mcp_manager: nil, mcp_client: nil)`. Do not change `GraphEngine` to suit the test.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`
Expected: fails. Before Tasks 1-5 it could not load the skill at all; run it now to confirm it passes only because of this plan's work, and note in the task report which assertion was the last to go green.

- [ ] **Step 3: Confirm it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_skills.rb`
Expected: pass. No implementation change should be needed — if one is, that is a gap in Tasks 1-5 and belongs there, not here.

- [ ] **Step 4: Document the format in the README**

In `README.md`, find the skills section (search for `config/riggs/skills/`) and add, matching that section's existing prose style:

````markdown
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
````

- [ ] **Step 5: Add the CHANGELOG entry**

Append to the `## 0.1.0` list in `CHANGELOG.md`:

```markdown
- Phase 8: `SkillRegistry` reads `SKILL.md` (YAML frontmatter plus a markdown body) as well as `SKILL.yml`, so an off-the-shelf skill file from the cross-harness convention drops into `config/riggs/skills/<name>/` and drives a workflow step unmodified. Both containers share one key space (`name`, `version`, `description`, `system_prompt`, `tools`, `mcp_servers`), the markdown body becomes the system prompt, and `SKILL.yml` wins if a directory holds both — no skill that exists today changes behavior. Skill descriptions now appear in `riggs skills:show`, `riggs skills:list`, and the web Skills table. **Behavior change:** a skill file that fails to parse is now skipped with a warning instead of raising. Previously one malformed `SKILL.yml` raised out of `SkillRegistry#list` and took down every command that touched the registry, including runs that wanted a different skill. Riggs still reads only `config/riggs/skills/`; `.agents/skills/` is deliberately not a discovery root, because a repo-local one would let a cloned repository supply a system prompt.
```

- [ ] **Step 6: Strike gap #7 in `docs/gaps.md`**

`docs/gaps.md` opens by stating how many items are open, then lists the shipped ones as struck-through bullets, then has an `## #7` section. Make three edits, keeping that file's existing voice:

1. Change the intro's count from three open to two, and add a struck-through bullet for #7 beside the existing ones:
   `- ~~**#7** Read `SKILL.md` frontmatter~~ — shipped. A skill bundle may be `SKILL.md` (YAML frontmatter plus a markdown body) or `SKILL.yml`, sharing one key space. Discovery is unchanged: `.agents/skills/` is deliberately not a root, since a repo-local one is gap #6's exposure.`
2. Delete the `## #7 — Read `SKILL.md` frontmatter` section, and its trailing `---` separator.
3. Fix the sentence naming which items remain, and re-point the "Cheapest item on this list" note if it referred to #7.

Read the file first — do not apply these from memory.

- [ ] **Step 7: Run RuboCop and the full suite**

Run: `bundle exec rubocop && bundle exec rake test`
Expected: no offenses; 0 failures.

- [ ] **Step 8: Commit**

```bash
git add test/test_skills.rb README.md CHANGELOG.md docs/gaps.md
git commit -m "Prove an off-the-shelf SKILL.md runs, and document the format"
```

---

## Sequencing

Task 1 produces the parser Task 2 consumes. Task 3 extends the hash Task 2 finalizes, and Task 5 renders what Task 3 adds. Task 4 is independent of 3 and 5 but must land after 2, since it rescues around the branch Task 2 introduces. Task 6 proves the whole chain and can only run last.

No task leaves the suite red, and no task leaves a merge blocker for a later one.

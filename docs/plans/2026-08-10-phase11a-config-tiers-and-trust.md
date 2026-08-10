# Phase 11a Implementation Plan — Config Tiers and Project Trust

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Riggs resolves identity, roles, providers and MCP servers from `~/.riggs/`, reads a repo's `.riggs/config.yml` only after that path is trusted, and gates every project-declared MCP server behind an explicit approval.

**Architecture:** Two new pure units — `Riggs::Trust` (the registry) and `Riggs::Config::Merge` (the algebra) — plus `Riggs::Config::Resolver`, which finds the tiers and applies the trust gate. `Identity.load_config` becomes a thin wrapper that returns the merged hash, so its eleven production call sites and every test that calls it keep working unchanged. Provenance travels beside the merged config so the MCP gate can tell a project-declared server from a global one, and so every run can print which tier chose the identity.

**Tech Stack:** Ruby 4.0 target, Thor CLI, Psych, Minitest, RuboCop.

**Spec:** `docs/specs/phase11-config-tiers-and-project-trust.md`. R11.1–R11.5 and R11.8 are in scope. R11.6 (attribution) and R11.7 (memory scoping) are Phase 11b and MUST NOT be implemented here.

## Global Constraints

- `bundle exec rubocop` clean across all files and `bundle exec rake test` at 0 failures / 0 errors before EVERY commit. Use `PATH="/Users/matt/.local/share/mise/shims:$PATH"`.
- NEVER use `--no-verify`. Do NOT `git push`. Do not create, switch, or delete branches — work on `phase-11-config-tiers`.
- `Layout/LineLength` Max is 130. No literal control characters in source.
- TDD: write the failing test, run it, watch it fail for the right reason, then implement. A test that passes the moment you write it is proving nothing.
- Do not modify `docs/specs/` or `docs/plans/`.
- Every commit message ends with:

```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CMEdcBvC8yT2U969uKGHoD
```

- Tests MUST NOT read or write the real `~/.riggs/`. Every test that touches a tier passes an explicit path into a `Dir.mktmpdir`. A test that pollutes the developer's home directory is a defect even when it passes.
- No credential value is ever written to `~/.riggs/trust.yml`, printed by an approval prompt, or included in a digest input. Only environment variable **names**.

### Two operator decisions this plan has pre-chosen

The spec left both open. The plan picks a default so implementation is not blocked; each is one line to reverse and each is called out at its site.

- **D1 — environment variable names ARE included in the approval digest** (Task 1). Renaming a forwarded variable therefore re-prompts. The alternative lets an approved server be pointed at a new secret with no re-approval, which is the worse failure.
- **D2 — an untrusted directory runs with the project tier ignored**, printing a notice, rather than refusing to run (Task 2). Safe by construction, and it keeps `riggs --help`, `riggs trust:list` and `riggs identity:show` usable in an unregistered directory.

---

### Task 1: `Riggs::Trust` — the trust and approval registry

**Governing standard:** `CLAUDE.md` in the repo root. Every class in this task
is under 100 lines of code, every method under 5, no method takes more than 4
parameters, there are no ternaries and no optional parameters. `Metrics` stays
disabled in `.rubocop.yml` — the 60 pre-existing files do not meet this bar and
turning the cops on globally would make the gate unpassable. This task meets it
by construction instead.

Bang names are retained (`grant!`, `forget!`, `approve_mcp!`): they are
destructive and the operator chose to keep them over `?` forms that would read
as pure queries.

**Files:**
- Create: `lib/riggs/trust/executable.rb`
- Create: `lib/riggs/trust/digest.rb`
- Create: `lib/riggs/trust/store.rb`
- Create: `lib/riggs/trust.rb`
- Modify: `lib/riggs.rb` (add `require_relative "riggs/trust"`)
- Test: `test/test_trust.rb`

**Interfaces produced** (Tasks 2, 6, 7 and 8 consume these):

- `Riggs::Trust.home -> String` — `ENV["RIGGS_HOME"]` or `~/.riggs`
- `Riggs::Trust.default_path -> String` — `<home>/trust.yml`
- `Riggs::Trust.default -> Trust` — the production instance
- `Riggs::Trust.new(path:) -> Trust` — `path` is REQUIRED, no default
- `Riggs::Trust.digest(command:, args:, env:) -> String` — all three required
- `Riggs::Trust.resolve_executable(command:, env:) -> String` — both required
- `#path -> String`
- `#trusted?(project_path) -> Boolean`
- `#trusted_at(project_path) -> String | nil`
- `#grant!(project_path) -> String` (the path)
- `#forget!(project_path) -> String | nil` (the path it forgot, else nil)
- `#projects -> Array<String>` (sorted)
- `#mcp_approved?(project_path, name, digest) -> Boolean`
- `#approve_mcp!(project_path, name, digest) -> String` (the digest)

Note `.new(path:)` is required with no default. A test that forgets it raises
`ArgumentError` immediately rather than silently writing to the developer's
real `~/.riggs/trust.yml`. The Global Constraint about not polluting `$HOME`
is enforced by the signature, not by reviewer vigilance.

- [ ] **Step 1: Write the failing test**

Create `test/test_trust.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestTrust < Minitest::Test
  def with_trust
    Dir.mktmpdir do |dir|
      yield Riggs::Trust.new(path: File.join(dir, "trust.yml")), dir
    end
  end

  def digest_for(command, args = [], env = {})
    Riggs::Trust.digest(command: command, args: args, env: env)
  end

  def test_an_unknown_path_is_not_trusted
    with_trust { |trust, _| refute trust.trusted?("/Users/matt/Projects/foo") }
  end

  def test_a_path_is_required_so_no_test_can_touch_the_real_home
    assert_raises(ArgumentError) { Riggs::Trust.new }
  end

  def test_grant_makes_a_path_trusted_and_records_a_timestamp
    with_trust do |trust, _|
      trust.grant!("/Users/matt/Projects/foo")
      assert trust.trusted?("/Users/matt/Projects/foo")
      refute_nil trust.trusted_at("/Users/matt/Projects/foo")
      refute trust.trusted?("/Users/matt/Projects/bar")
    end
  end

  def test_grant_is_idempotent_and_does_not_move_the_original_timestamp
    with_trust do |trust, _|
      trust.grant!("/p")
      first = trust.trusted_at("/p")
      trust.grant!("/p")
      assert_equal first, trust.trusted_at("/p")
    end
  end

  # forget! returns what it removed, not a boolean: `?` would read as a pure
  # query on a method that deletes an entry and rewrites the file.
  def test_forget_returns_the_path_it_forgot_and_nil_when_there_was_nothing
    with_trust do |trust, _|
      trust.grant!("/p")
      assert_equal "/p", trust.forget!("/p")
      refute trust.trusted?("/p")
      assert_nil trust.forget!("/p")
    end
  end

  def test_projects_lists_granted_paths_sorted
    with_trust do |trust, _|
      trust.grant!("/b")
      trust.grant!("/a")
      assert_equal ["/a", "/b"], trust.projects
    end
  end

  def test_the_file_is_created_private_to_the_owner
    with_trust do |trust, _|
      trust.grant!("/p")
      assert_equal 0o600, File.stat(trust.path).mode & 0o777
    end
  end

  # Writing content first and chmod'ing after leaves a window in which the
  # file is world-readable WITH the project list already in it. Creating the
  # node private before any content is written closes that window; a file that
  # arrived world-readable by some other route is tightened on the next write.
  def test_a_world_readable_file_is_tightened_on_write
    with_trust do |trust, _|
      FileUtils.mkdir_p(File.dirname(trust.path))
      File.write(trust.path, "---\nprojects: {}\n")
      File.chmod(0o644, trust.path)
      trust.grant!("/p")
      assert_equal 0o600, File.stat(trust.path).mode & 0o777
    end
  end

  def test_a_digest_is_stable_across_calls
    a = digest_for("npx", %w[-y hb-mcp], { "HB_TOKEN" => "sk-1" })
    b = digest_for("npx", %w[-y hb-mcp], { "HB_TOKEN" => "sk-2" })
    assert_equal a, b
    assert_match(/\Asha256:[0-9a-f]{64}\z/, a)
  end

  def test_a_digest_changes_when_the_command_or_arguments_change
    base = digest_for("npx", %w[-y hb-mcp])
    refute_equal base, digest_for("node", %w[-y hb-mcp])
    refute_equal base, digest_for("npx", %w[-y evil-mcp])
    refute_equal base, digest_for("npx", %w[-y hb-mcp --extra])
  end

  # D1: names are part of the identity of a server, values never are.
  def test_a_digest_changes_when_a_forwarded_variable_is_renamed
    a = digest_for("x", [], { "HB_TOKEN" => "v" })
    b = digest_for("x", [], { "OTHER_TOKEN" => "v" })
    refute_equal a, b
  end

  def test_a_digest_ignores_the_order_variables_were_declared_in
    a = digest_for("x", [], { "A" => "1", "B" => "2" })
    b = digest_for("x", [], { "B" => "2", "A" => "1" })
    assert_equal a, b
  end

  def test_approval_is_recorded_per_project_and_per_server
    with_trust do |trust, _|
      trust.grant!("/p")
      d = digest_for("npx", %w[hb])
      trust.approve_mcp!("/p", "honeybadger", d)
      assert trust.mcp_approved?("/p", "honeybadger", d)
      refute trust.mcp_approved?("/other", "honeybadger", d)
      refute trust.mcp_approved?("/p", "context7", d)
    end
  end

  def test_a_changed_command_is_no_longer_approved
    with_trust do |trust, _|
      trust.grant!("/p")
      trust.approve_mcp!("/p", "hb", digest_for("npx", %w[hb]))
      refute trust.mcp_approved?("/p", "hb", digest_for("npx", %w[hb --now-with-extras]))
    end
  end

  # An absent approval must not compare equal to an absent digest.
  def test_an_unrecorded_server_is_not_approved_by_a_nil_digest
    with_trust do |trust, _|
      trust.grant!("/p")
      refute trust.mcp_approved?("/p", "never-approved", nil)
    end
  end

  # The two gates must stay two gates.
  def test_approving_a_server_for_an_untrusted_path_raises
    with_trust do |trust, _|
      err = assert_raises(Riggs::Error) do
        trust.approve_mcp!("/p", "hb", digest_for("npx"))
      end
      assert_includes err.message, "not trusted"
      refute trust.trusted?("/p")
    end
  end

  def test_recording_an_approval_never_creates_trust
    with_trust do |trust, _|
      trust.grant!("/p")
      trust.approve_mcp!("/p", "hb", digest_for("npx"))
      trust.forget!("/p")
      refute trust.trusted?("/p"), "forgetting trust must not be undone by a surviving approval entry"
    end
  end

  # The digest binds the binary, not the name that happened to select it.
  def test_a_digest_binds_the_path_resolved_executable
    Dir.mktmpdir do |dir|
      %w[a b].each { |sub| write_fake(File.join(dir, sub), "fakemcp") }
      a = digest_for("fakemcp", [], { "PATH" => File.join(dir, "a") })
      b = digest_for("fakemcp", [], { "PATH" => File.join(dir, "b") })
      refute_equal a, b, "same command name, different binary, must not share an approval"
    end
  end

  def test_an_unresolvable_command_still_digests_stably
    a = digest_for("definitely-not-on-this-path-9f2a", [], { "PATH" => "/nonexistent" })
    b = digest_for("definitely-not-on-this-path-9f2a", [], { "PATH" => "/nonexistent" })
    assert_equal a, b
  end

  # POSIX: an empty PATH component means the current directory. File.join("", c)
  # yields "/c", so a naive implementation digests a file in the filesystem
  # root while the child executes one in the working directory.
  def test_an_empty_path_component_resolves_to_the_current_directory
    Dir.mktmpdir do |dir|
      bin = write_fake(dir, "fakemcp")
      Dir.chdir(dir) do
        resolved = Riggs::Trust.resolve_executable(command: "fakemcp", env: { "PATH" => ":/nonexistent" })
        assert_equal File.realpath(bin), resolved
      end
    end
  end

  def test_a_relative_path_component_resolves_to_an_absolute_path
    Dir.mktmpdir do |dir|
      bin = write_fake(File.join(dir, "tools"), "fakemcp")
      Dir.chdir(dir) do
        resolved = Riggs::Trust.resolve_executable(command: "fakemcp", env: { "PATH" => "tools" })
        assert_equal File.realpath(bin), resolved
        assert resolved.start_with?("/"), "a digest input must be an absolute path"
      end
    end
  end

  def test_a_swapped_symlink_is_a_different_approval
    Dir.mktmpdir do |dir|
      %w[a b].each { |n| write_fake(dir, n) }
      link = File.join(dir, "fakemcp")
      File.symlink(File.join(dir, "a"), link)
      first = digest_for(link)
      File.unlink(link)
      File.symlink(File.join(dir, "b"), link)
      refute_equal first, digest_for(link)
    end
  end

  # The bug: a frozen constant dup'd on read shares its nested hash.
  def test_two_registries_with_no_file_do_not_share_state
    Dir.mktmpdir do |dir|
      a = Riggs::Trust.new(path: File.join(dir, "a.yml"))
      b = Riggs::Trust.new(path: File.join(dir, "b.yml"))
      a.grant!("/p")
      refute b.trusted?("/p"), "a grant in one registry must not appear in another"
    end
  end

  # The strongest guarantee in this file: assert on the bytes, not the intent.
  def test_no_environment_variable_value_reaches_the_file
    with_trust do |trust, _|
      trust.grant!("/p")
      sentinel = "SENTINEL-b3f1c9d2-do-not-persist"
      d = digest_for("npx", %w[hb], { "HB_TOKEN" => sentinel })
      trust.approve_mcp!("/p", "hb", d)
      contents = File.read(trust.path)
      refute_includes contents, sentinel
      refute_includes contents, "HB_TOKEN"
      assert_includes contents, "hb", "the server name itself must still be recorded"
    end
  end

  private

  def write_fake(dir, name)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end
end
```

- [ ] **Step 2: Run the test and watch it fail for the right reason**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_trust.rb`

Expected: `NameError: uninitialized constant Riggs::Trust`. Any other failure
means the harness is broken, not the feature missing — fix that first.

- [ ] **Step 3: Create `lib/riggs/trust/executable.rb`**

```ruby
# frozen_string_literal: true

module Riggs
  class Trust
    # Turns a configured command into the absolute path that will actually be
    # spawned. A digest over the literal string "mcp" binds nothing: a later
    # PATH change selects a different binary under the same name and the old
    # approval still matches. Resolving here, and re-resolving at spawn, means
    # a different binary is a different digest.
    #
    # It also keeps PATH itself out of the digest input, which recording PATH
    # as an environment value would not.
    class Executable
      # POSIX: an EMPTY PATH component means the current directory, so
      # PATH=":/usr/bin" can run ./mcp. File.join("", cmd) yields "/cmd" --
      # a file in the filesystem root, not the one that runs.
      CURRENT_DIRECTORY = "."

      # Where exec looks when PATH is unset in the child.
      DEFAULT_PATH = "/bin:/usr/bin"

      def self.resolve(command:, env:)
        new(command: command, env: env).path
      end

      def initialize(command:, env:)
        @command = command.to_s
        @env = (env || {}).transform_keys(&:to_s)
      end

      # An unresolvable name digests as "unresolved:<name>" so approval still
      # binds something stable and the spawn fails on its own terms, not here.
      def path
        return realpath(File.expand_path(@command)) if qualified?

        found = candidates.detect { |candidate| runnable?(candidate) }
        return "unresolved:#{@command}" if found.nil?

        realpath(found)
      end

      private

      def qualified?
        @command.include?(File::SEPARATOR)
      end

      def candidates
        search_path.lazy.map { |dir| expand(dir) }
      end

      def expand(dir)
        File.expand_path(File.join(base_for(dir), @command))
      end

      def base_for(dir)
        return CURRENT_DIRECTORY if dir.empty?

        dir
      end

      def runnable?(candidate)
        File.file?(candidate) && File.executable?(candidate)
      end

      def search_path
        raw_path.split(File::PATH_SEPARATOR, -1)
      end

      # A key present with a NIL value means "unset in the child" to Open3, and
      # exec then falls back to a system default path rather than to ours. That
      # is why this checks for the key and then for the value, not just the
      # value.
      def raw_path
        return @env["PATH"] || DEFAULT_PATH if @env.key?("PATH")

        ENV.fetch("PATH", DEFAULT_PATH)
      end

      # The winner is realpath'd so a swapped symlink is a different path, and
      # therefore a different approval.
      def realpath(candidate)
        File.realpath(candidate)
      rescue SystemCallError
        candidate
      end
    end
  end
end
```

- [ ] **Step 4: Create `lib/riggs/trust/digest.rb`**

```ruby
# frozen_string_literal: true

require "digest"
require "json"

module Riggs
  class Trust
    # The identity of an approved MCP server: what will run, with which
    # arguments, forwarding which environment variable NAMES.
    #
    # D1 -- names are part of that identity, so renaming a forwarded variable
    # re-prompts. Excluding them would let an approved server be pointed at a
    # different secret with no re-approval, which is the worse failure.
    #
    # Values never participate. A digest is one-way, but the rule "no value
    # enters this subsystem" is checkable and "no value escapes this hash" is
    # not.
    class Digest
      def self.of(command:, args:, env:)
        new(command: command, args: args, env: env).value
      end

      def initialize(command:, args:, env:)
        @command = command
        @args = Array(args).map(&:to_s)
        @env = env || {}
      end

      # ::Digest, not Digest -- inside this class the bare constant resolves to
      # this class itself, not to the stdlib.
      def value
        "sha256:#{::Digest::SHA256.hexdigest(canonical)}"
      end

      private

      def canonical
        JSON.generate("command" => resolved, "args" => @args, "env_keys" => env_keys)
      end

      def resolved
        Executable.resolve(command: @command, env: @env)
      end

      def env_keys
        @env.keys.map(&:to_s).sort
      end
    end
  end
end
```

- [ ] **Step 5: Create `lib/riggs/trust/store.rb`**

```ruby
# frozen_string_literal: true

require "psych"
require "fileutils"

module Riggs
  class Trust
    # The YAML file behind the registry. Machine-written: riggs rewrites it on
    # every approval, which is why it is a separate file from the
    # hand-authored ~/.riggs/config.yml.
    class Store
      attr_reader :path

      def initialize(path:)
        @path = path
      end

      def read
        return empty unless File.exist?(@path)

        loaded || empty
      end

      def write(data)
        FileUtils.mkdir_p(File.dirname(@path))
        create_private
        File.write(@path, Psych.dump(data))
        @path
      end

      private

      # A fresh nested hash every call. A shared frozen constant dup'd on read
      # would freeze only the OUTER hash, so every caller would mutate the same
      # inner "projects" hash and one registry's grants would leak into every
      # other.
      def empty
        { "projects" => {} }
      end

      # Neither symbols nor aliases have any business in a machine-written
      # registry, so this is the strict form rather than the permissive one
      # Identity uses for hand-authored config.
      def loaded
        Psych.safe_load(File.read(@path), permitted_classes: [], aliases: false)
      end

      # The node is created 0600 BEFORE any content is written, and an existing
      # file is tightened before it is rewritten. Writing content first and
      # chmod'ing after leaves a window in which the file is world-readable
      # with the operator's project list already in it.
      def create_private
        File.open(@path, File::WRONLY | File::CREAT, 0o600) { nil }
        File.chmod(0o600, @path)
      end
    end
  end
end
```

- [ ] **Step 6: Create `lib/riggs/trust.rb`**

```ruby
# frozen_string_literal: true

require "time"
require_relative "trust/executable"
require_relative "trust/digest"
require_relative "trust/store"

module Riggs
  # Which absolute paths the operator has trusted, and which MCP servers they
  # have approved within each.
  #
  # Nothing secret is ever stored here. Approvals are recorded as a digest of
  # the command, its arguments, and the NAMES of forwarded environment
  # variables.
  class Trust
    # Resolved at call time, not as a load-time constant, so a test -- and an
    # operator with more than one riggs install -- can point the whole global
    # tier somewhere else. The same escape hatch CODEX_HOME provides.
    def self.home
      ENV["RIGGS_HOME"] || File.join(Dir.home, ".riggs")
    end

    def self.default_path
      File.join(home, "trust.yml")
    end

    def self.default
      new(path: default_path)
    end

    def self.digest(command:, args:, env:)
      Digest.of(command: command, args: args, env: env)
    end

    def self.resolve_executable(command:, env:)
      Executable.resolve(command: command, env: env)
    end

    # `path` is required and has no default. A caller that forgets it raises
    # ArgumentError instead of quietly writing to the developer's real
    # ~/.riggs/trust.yml.
    def initialize(path:)
      @store = Store.new(path: path)
    end

    def path
      @store.path
    end

    # Trust is `trusted_at` being PRESENT, not an entry existing. An entry is
    # also created by recording an approval, and conflating the two would mean
    # approving one MCP server silently trusts the whole project config --
    # collapsing the two gates this phase exists to separate.
    def trusted?(project_path)
      !trusted_at(project_path).nil?
    end

    def trusted_at(project_path)
      entry(project_path)&.fetch("trusted_at", nil)
    end

    def grant!(project_path)
      update { |data| project_entry(data, project_path)["trusted_at"] ||= now }
      project_path.to_s
    end

    # Returns the path it forgot, or nil when there was nothing to forget.
    # Deliberately not a boolean and deliberately not `forget?`: this deletes
    # an entry and rewrites the file, and `?` reads as a pure query.
    def forget!(project_path)
      data = @store.read
      return nil if projects_in(data).delete(project_path.to_s).nil?

      @store.write(data)
      project_path.to_s
    end

    def projects
      projects_in(@store.read).keys.sort
    end

    # An absent approval must not compare equal to an absent digest, so the
    # nil check is separate from the comparison.
    def mcp_approved?(project_path, name, digest)
      found = recorded(project_path, name)
      !found.nil? && found == digest
    end

    # Approving requires trust first: the declaration being approved lives in a
    # file that may not be read yet. This never writes trusted_at.
    def approve_mcp!(project_path, name, digest)
      require_trust!(project_path, name)
      update { |data| approvals(data, project_path)[name.to_s] = digest }
      digest
    end

    private

    def recorded(project_path, name)
      entry(project_path)&.dig("mcp_approved", name.to_s)
    end

    def require_trust!(project_path, name)
      return if trusted?(project_path)

      raise Error, "cannot approve MCP server '#{name}' for #{project_path}: " \
                   "the path is not trusted. Run 'riggs trust' there first."
    end

    def approvals(data, project_path)
      project_entry(data, project_path)["mcp_approved"] ||= {}
    end

    def project_entry(data, project_path)
      projects_in(data)[project_path.to_s] ||= {}
    end

    def projects_in(data)
      data["projects"] ||= {}
    end

    def entry(project_path)
      projects_in(@store.read)[project_path.to_s]
    end

    def update
      data = @store.read
      yield data
      @store.write(data)
    end

    def now
      Time.now.utc.iso8601
    end
  end
end
```

- [ ] **Step 7: Wire it into the entrypoint**

In `lib/riggs.rb`, add above `require_relative "riggs/config_store"`:

```ruby
require_relative "riggs/trust"
```

- [ ] **Step 8: Run the test and watch it pass**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_trust.rb`

Expected: 24 runs, 0 failures, 0 errors.

- [ ] **Step 9: Prove the guards are load-bearing**

Each mutation must REMOVE protection, not reword it. Apply one, confirm the
named test goes red, then REVERT it. A mutation that leaves an unconditional
`raise` in place proves nothing.

1. In `Executable#base_for`, delete the `return CURRENT_DIRECTORY if dir.empty?`
   line so an empty component falls through to `dir`.
   Expect `test_an_empty_path_component_resolves_to_the_current_directory` to
   fail. The candidate becomes `/fakemcp`, which does not exist, so the search
   falls through the rest of the PATH and the assertion sees
   `unresolved:fakemcp`. Either way the guard is proven load-bearing.
2. In `Trust#require_trust!`, change `return if trusted?(project_path)` to
   `return`. Expect `test_approving_a_server_for_an_untrusted_path_raises` to
   fail because no error is raised.
3. In `Store#create_private`, delete the `File.chmod` line. Expect
   `test_a_world_readable_file_is_tightened_on_write` to fail with 0644.
4. In `Digest#canonical`, drop the `"env_keys"` pair entirely. Expect
   `test_a_digest_changes_when_a_forwarded_variable_is_renamed` to fail.

- [ ] **Step 10: Run the full gate and commit**

```bash
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rubocop
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rake test
git add lib/riggs/trust.rb lib/riggs/trust/ lib/riggs.rb test/test_trust.rb
git commit -m "Add Riggs::Trust registry for project trust and MCP approval"
```

### Task 2: `Riggs::Config::Resolver` — tier paths and the trust gate

**Files:**
- Create: `lib/riggs/config/resolver.rb`
- Test: `test/test_config_resolver.rb`
- Modify: `lib/riggs.rb`

**Interfaces:**
- Consumes: `Riggs::Trust` from Task 1.
- Produces:
  - `Resolver.project_path(cwd = Dir.pwd) -> String` — git toplevel, else expanded cwd. Memoized per cwd.
  - `Resolver.reset_cache!` — test hook.
  - `Resolver.new(cwd:, trust:, global_config:) #resolve -> Resolver::Result`
  - `Result` members: `global`, `project`, `project_path`, `project_config_path`, `trusted`, `legacy`

- [ ] **Step 1: Write the failing tests**

Create `test/test_config_resolver.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestConfigResolver < Minitest::Test
  def setup
    Riggs::Config::Resolver.reset_cache!
  end

  def teardown
    Riggs::Config::Resolver.reset_cache!
  end

  def in_sandbox
    Dir.mktmpdir do |dir|
      root = File.realpath(dir)
      trust = Riggs::Trust.new(path: File.join(root, "trust.yml"))
      global = File.join(root, "global.yml")
      File.write(global, Psych.dump("users" => { "matt" => { "role" => "pm" } }))
      yield(root, trust, global)
    end
  end

  def write_project(root, hash)
    FileUtils.mkdir_p(File.join(root, ".riggs"))
    File.write(File.join(root, ".riggs", "config.yml"), Psych.dump(hash))
  end

  def resolve(root, trust, global, cwd: root)
    Riggs::Config::Resolver.new(cwd: cwd, trust: trust, global_config: global).resolve
  end

  def test_the_global_tier_loads_without_any_project_file
    in_sandbox do |root, trust, global|
      result = resolve(root, trust, global)
      assert_equal({ users: { matt: { role: "pm" } } }, result.global)
      assert_empty result.project
    end
  end

  def test_an_untrusted_project_file_is_not_read
    in_sandbox do |root, trust, global|
      write_project(root, "users" => { "evil" => { "role" => "pm" } })
      result = resolve(root, trust, global)
      refute result.trusted
      assert_empty result.project
    end
  end

  # An untrusted path must not even be NAMED, or ConfigStore reads it.
  def test_an_untrusted_project_config_path_is_not_exposed
    in_sandbox do |root, trust, global|
      write_project(root, "default_user" => "evil")
      assert_nil resolve(root, trust, global).project_config_path
      trust.grant!(root)
      refute_nil resolve(root, trust, global).project_config_path
    end
  end

  def test_project_skill_and_workflow_roots_are_empty_until_trusted
    in_sandbox do |root, trust, global|
      resolver = Riggs::Config::Resolver.new(cwd: root, trust: trust, global_config: global)
      assert_nil resolver.project_roots[:skills]
      assert_nil resolver.project_roots[:workflows]
      trust.grant!(root)
      fresh = Riggs::Config::Resolver.new(cwd: root, trust: trust, global_config: global)
      assert_equal File.join(root, "config", "riggs", "skills"), fresh.project_roots[:skills]
    end
  end

  def test_a_trusted_project_file_is_read
    in_sandbox do |root, trust, global|
      write_project(root, "users" => { "sam" => { "role" => "viewer" } })
      trust.grant!(root)
      result = resolve(root, trust, global)
      assert result.trusted
      assert_equal({ sam: { role: "viewer" } }, result.project[:users])
    end
  end

  def test_a_legacy_agent_hubrc_is_read_as_the_project_tier_when_trusted
    in_sandbox do |root, trust, global|
      File.write(File.join(root, ".agent_hubrc"), Psych.dump("default_user" => "sam"))
      trust.grant!(root)
      result = resolve(root, trust, global)
      assert result.legacy
      assert_equal "sam", result.project[:default_user]
    end
  end

  def test_the_modern_project_file_wins_over_a_legacy_one
    in_sandbox do |root, trust, global|
      write_project(root, "default_user" => "modern")
      File.write(File.join(root, ".agent_hubrc"), Psych.dump("default_user" => "legacy"))
      trust.grant!(root)
      result = resolve(root, trust, global)
      refute result.legacy
      assert_equal "modern", result.project[:default_user]
    end
  end

  # R11.1: the project file is read from project_path, not from cwd. Inside a
  # repository that makes a subdirectory resolve its parent's config -- which
  # is the whole reason project_path is the git toplevel.
  def test_a_subdirectory_of_a_repository_reads_the_repository_project_file
    in_sandbox do |root, trust, global|
      system("git", "init", "--quiet", root, out: File::NULL, err: File::NULL)
      write_project(root, "default_user" => "sam")
      trust.grant!(root)
      sub = File.join(root, "lib", "deep")
      FileUtils.mkdir_p(sub)
      result = Riggs::Config::Resolver.new(cwd: sub, trust: trust, global_config: global).resolve
      assert_equal root, result.project_path
      assert_equal "sam", result.project[:default_user]
    end
  end

  # Outside a repository the same containment rule must hold, so the walk up
  # adopts the nearest ancestor carrying a .riggs/config.yml.
  def test_outside_a_repository_a_subdirectory_adopts_a_marked_ancestor
    in_sandbox do |root, trust, global|
      write_project(root, "default_user" => "sam")
      trust.grant!(root)
      sub = File.join(root, "plain", "deep")
      FileUtils.mkdir_p(sub)
      result = Riggs::Config::Resolver.new(cwd: sub, trust: trust, global_config: global).resolve
      assert_equal root, result.project_path
      assert_equal "sam", result.project[:default_user]
    end
  end

  def test_an_unmarked_directory_outside_a_repository_is_its_own_project
    in_sandbox do |root, trust, global|
      sub = File.join(root, "plain", "deep")
      FileUtils.mkdir_p(sub)
      result = Riggs::Config::Resolver.new(cwd: sub, trust: trust, global_config: global).resolve
      assert_equal sub, result.project_path
      refute result.trusted
    end
  end

  # The walk must stop before $HOME, or ~/.riggs/config.yml -- the GLOBAL
  # tier -- would mark $HOME as every directory's project root.
  def test_the_ancestor_walk_never_adopts_home
    in_sandbox do |root, _trust, _global|
      FileUtils.mkdir_p(File.join(root, ".riggs"))
      File.write(File.join(root, ".riggs", "config.yml"), Psych.dump({}))
      sub = File.join(root, "anything", "deep")
      FileUtils.mkdir_p(sub)
      assert_equal sub, Riggs::Config::Resolver.send(:marked_ancestor, sub, home: root) || sub
    end
  end

  def test_project_path_is_the_git_toplevel_when_inside_a_working_tree
    in_sandbox do |root, _trust, _global|
      system("git", "init", "--quiet", root, out: File::NULL, err: File::NULL)
      sub = File.join(root, "lib", "deep")
      FileUtils.mkdir_p(sub)
      assert_equal root, Riggs::Config::Resolver.project_path(sub)
    end
  end

  def test_project_path_falls_back_to_the_directory_outside_a_repository
    in_sandbox do |root, _trust, _global|
      assert_equal root, Riggs::Config::Resolver.project_path(root)
    end
  end

  # R11.1: <project>/.riggs/config.yml and ~/.riggs/config.yml are the same
  # file when the project is $HOME, and reading one file as both tiers makes
  # every redefinition check fire against itself.
  def test_home_is_never_a_project
    in_sandbox do |root, trust, _global|
      global = File.join(root, ".riggs", "config.yml")
      FileUtils.mkdir_p(File.dirname(global))
      File.write(global, Psych.dump("users" => { "matt" => { "role" => "pm" } }))
      trust.grant!(root)
      result = Riggs::Config::Resolver.new(
        cwd: root, trust: trust, global_config: global, home: root
      ).resolve
      assert_nil result.project_config_path
      assert_empty result.project
      assert_equal({ matt: { role: "pm" } }, result.global[:users])
    end
  end

  def test_a_missing_global_config_resolves_to_an_empty_tier_rather_than_raising
    in_sandbox do |root, trust, _global|
      result = resolve(root, trust, File.join(root, "absent.yml"))
      assert_empty result.global
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_config_resolver.rb`
Expected: FAIL — `NameError: uninitialized constant Riggs::Config`

- [ ] **Step 3: Implement the resolver**

Create `lib/riggs/config/resolver.rb`:

```ruby
# frozen_string_literal: true

require "psych"
require "open3"
require_relative "../trust"

module Riggs
  module Config
    # Finds the two configuration tiers and decides whether the project one may
    # be read at all. It does not merge them -- Config::Merge does that -- so
    # that "which files exist and may we look at them" stays separable from
    # "what do they mean together".
    class Resolver
      PROJECT_CONFIG = File.join(".riggs", "config.yml")

      # Read as the project tier with a deprecation notice. 46 references
      # across nine non-doc files; removing it is not this phase.
      LEGACY_PROJECT_CONFIGS = [".agent_hubrc", File.join("config", ".agent_hubrc"),
                                File.join("config", "agent_hubrc")].freeze

      Result = Struct.new(:global, :project, :project_path, :project_config_path,
                          :trusted, :legacy, keyword_init: true)

      class << self
        # Both resolved at call time, honouring RIGGS_HOME, so tests and CLI
        # runs can target a temporary global tier instead of the developer's
        # own. A load-time constant off Dir.home cannot be overridden and
        # makes every CLI-level test write to the real ~/.riggs.
        def riggs_home
          Trust.home
        end

        def global_config
          File.join(riggs_home, "config.yml")
        end

        # Git toplevel, so that trust, cost and memory are repository-scoped:
        # ~/Projects/riggs and ~/Projects/agentcrm are different projects, and
        # ~/Projects/agentcrm/lib is part of agentcrm. Keying on the working
        # directory would make a run from <repo>/lib a different project than
        # one from <repo> -- separate trust prompt, separate memory, separate
        # cost bucket.
        #
        # Outside a repository the same rule has to hold, so a directory with
        # no git toplevel walks up looking for a .riggs/config.yml and adopts
        # that ancestor. The walk stops BEFORE $HOME: ~/.riggs/config.yml is
        # the global tier, and treating it as a project marker would make
        # every directory under $HOME resolve to $HOME -- one project for the
        # whole machine, which is the $HOME collision wearing a different hat.
        def project_path(cwd = Dir.pwd)
          key = File.expand_path(cwd)
          cache.fetch(key) { cache[key] = git_toplevel(key) || marked_ancestor(key) || key }
        end

        def reset_cache!
          @cache = {}
        end

        private

        def cache
          @cache ||= {}
        end

        def git_toplevel(cwd)
          out, _err, status = Open3.capture3("git", "-C", cwd, "rev-parse", "--show-toplevel")
          return nil unless status.success?

          path = out.strip
          path.empty? ? nil : File.expand_path(path)
        rescue StandardError
          nil
        end

        def marked_ancestor(cwd, home: Dir.home)
          stop = File.expand_path(home)
          dir = cwd
          while dir != stop && dir != "/" && File.dirname(dir) != dir
            return dir if File.exist?(File.join(dir, PROJECT_CONFIG))

            dir = File.dirname(dir)
          end
          nil
        end
      end

      def initialize(cwd: Dir.pwd, trust: nil, global_config: nil, home: Dir.home)
        @cwd = cwd
        @trust = trust || Trust.new
        @global_config = global_config || self.class.global_config
        @home = home
      end

      def resolve
        pp = self.class.project_path(@cwd)
        global = load_yaml(@global_config)
        return home_result(global, pp) if home?(pp)

        path, legacy = project_config_for(pp)
        trusted = @trust.trusted?(pp)
        Result.new(
          global: global,
          project: trusted && path ? load_yaml(path) : {},
          project_path: pp,
          # nil unless trusted, deliberately. This value is what
          # Identity.config_path returns and what the web app hands to
          # ConfigStore (lib/riggs/web/app.rb:96-98), and ConfigStore reads it
          # with Identity.load_config(path) -- a raw single-file reader that
          # never consults trust. Exposing the path of a file the resolver just
          # declined to open would let /config read and write it over HTTP.
          project_config_path: trusted ? path : nil,
          trusted: trusted,
          legacy: trusted && legacy
        )
      end

      # Project skill and workflow roots, empty unless the path is trusted. A
      # skill declares mcp_servers, which pins which servers a step may reach;
      # a workflow declares providers and relay_chain, which decides what gets
      # dispatched and what pays. Gating the config file while loading
      # executable declarations from the same untrusted directory would leave
      # the door open beside the lock.
      def project_roots
        pp = self.class.project_path(@cwd)
        return { skills: nil, workflows: nil } unless @trust.trusted?(pp)

        { skills: File.join(pp, "config", "riggs", "skills"),
          workflows: File.join(pp, "config", "riggs", "workflows") }
      end

      private

      # R11.1: <project>/.riggs/config.yml IS ~/.riggs/config.yml when the
      # project is $HOME. There is no project tier there.
      def home?(project_path)
        File.expand_path(project_path) == File.expand_path(@home)
      end

      def home_result(global, project_path)
        Result.new(global: global, project: {}, project_path: project_path,
                   project_config_path: nil, trusted: @trust.trusted?(project_path), legacy: false)
      end

      def project_config_for(project_path)
        modern = File.join(project_path, PROJECT_CONFIG)
        return [modern, false] if File.exist?(modern)

        legacy = LEGACY_PROJECT_CONFIGS.map { |c| File.join(project_path, c) }.find { |p| File.exist?(p) }
        legacy ? [legacy, true] : [nil, false]
      end

      def load_yaml(path)
        return {} unless path && File.exist?(path)

        raw = Psych.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
        Identity.deep_symbolize(raw)
      end
    end
  end
end
```

Add to `lib/riggs.rb`:

```ruby
require_relative "riggs/config/resolver"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_config_resolver.rb`
Expected: PASS, 10 runs, 0 failures.

- [ ] **Step 5: Prove the untrusted file is never EXECUTED, not merely ignored**

Add this test. Asserting that a merged hash lacks a key passes even if the file
was read, parsed, and then discarded — and the property that matters is that
nothing in it ran.

```ruby
  def test_an_untrusted_project_file_declaring_an_mcp_server_never_spawns_it
    in_sandbox do |root, trust, global|
      marker = File.join(root, "pwned-9f2a")
      write_project(root, "mcp_servers" => {
                      "evil" => { "command" => "/bin/sh", "args" => ["-c", "touch #{marker}"] }
                    })
      result = resolve(root, trust, global)
      refute result.trusted

      # provenance :global deliberately. The MCP approval gate is Task 6's
      # job and would block this spawn on its own, which would make the test
      # pass with the RESOLVER gate removed -- proving Task 6 twice and Task 2
      # not at all. Declaring the server global strips that second gate away
      # so the only thing standing between the config and the marker file is
      # the trust check under test.
      servers = result.project[:mcp_servers] || {}
      prov = servers.keys.to_h { |k| [k, :global] }
      Riggs::MCP::Manager.from_config(servers, provenance: prov).list_tools
      refute File.exist?(marker), "an untrusted project's MCP command must never run"
    end
  end
```

Then mutate: change `trusted && path ? load_yaml(path) : {}` to
`path ? load_yaml(path) : {}`. BOTH `test_an_untrusted_project_file_is_not_read`
and the marker test MUST fail. Revert and paste both outputs.

If the marker test still passes under that mutation, stop — it means a
downstream gate is covering for the one under test, and the test is measuring
the wrong thing.

This is the single most important line in the phase. If deleting the gate does
not fail a test, the gate is decorative.

- [ ] **Step 6: Run the full gate and commit**

```bash
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rubocop
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rake test
git add lib/riggs/config/resolver.rb lib/riggs.rb test/test_config_resolver.rb
git commit -m "Add Config::Resolver with git-scoped project paths and the trust gate"
```

---

### Task 3: `Riggs::Config::Merge` — the three merge algebras

**Files:**
- Create: `lib/riggs/config/merge.rb`
- Test: `test/test_config_merge.rb`
- Modify: `lib/riggs.rb`

**Interfaces:**
- Consumes: `Identity.deep_symbolize`, `Identity::DEFAULT_ROLES`.
- Produces:
  - `Merge.call(global:, project:, global_path:, project_path:) -> Merge::Merged`
  - `Merged` members: `config` (the merged hash), `provenance` (a hash of `{users:, roles:, providers:, mcp_servers:, default_user:}` mapping each name to `:global` or `:project`)

Provenance exists because Task 6 must gate **project-declared** MCP servers only, and Task 8 must print which tier chose the identity. Recomputing that at either call site would mean two places deciding what "came from the project" means.

- [ ] **Step 1: Write the failing tests**

Create `test/test_config_merge.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class TestConfigMerge < Minitest::Test
  G = "/home/me/.riggs/config.yml"
  P = "/repo/.riggs/config.yml"

  def merge(global, project)
    Riggs::Config::Merge.call(global: global, project: project, global_path: G, project_path: P)
  end

  def test_an_empty_project_tier_returns_the_global_tier
    result = merge({ users: { matt: { role: "pm" } } }, {})
    assert_equal({ matt: { role: "pm" } }, result.config[:users])
  end

  # --- the allowlist ---

  def test_sqlite_path_in_the_project_tier_is_a_hard_error_naming_both_files
    err = assert_raises(Riggs::Error) { merge({}, { sqlite_path: "/tmp/x.sqlite3" }) }
    assert_includes err.message, "sqlite_path"
    assert_includes err.message, G
    assert_includes err.message, P
  end

  # The key a denylist missed. vector_path and memory_path reach
  # enable_load_extension/load_extension, so this is arbitrary native code.
  def test_sqlite_memory_in_the_project_tier_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({}, { sqlite_memory: { vector_path: "/tmp/evil.dylib" } })
    end
    assert_includes err.message, "sqlite_memory"
  end

  def test_an_unrecognized_top_level_key_is_a_hard_error_listing_the_permitted_ones
    err = assert_raises(Riggs::Error) { merge({}, { something_new: true }) }
    assert_includes err.message, "something_new"
    %w[default_user mcp_servers providers roles users].each { |k| assert_includes err.message, k }
  end

  # --- roles: add yes, redefine no ---

  def test_a_project_may_define_a_role_the_global_tier_does_not
    result = merge({ roles: { pm: %w[publish] } }, { roles: { client_reviewer: %w[inspect_run] } })
    assert_equal %w[publish], result.config[:roles][:pm]
    assert_equal %w[inspect_run], result.config[:roles][:client_reviewer]
    assert_equal :project, result.provenance[:roles][:client_reviewer]
    assert_equal :global, result.provenance[:roles][:pm]
  end

  def test_a_project_redefining_a_global_role_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({ roles: { engineer: %w[run_workflow] } }, { roles: { engineer: %w[manage_mcp] } })
    end
    assert_includes err.message, "engineer"
    assert_includes err.message, G
    assert_includes err.message, P
  end

  # --- users: merge by key, override allowed ---

  def test_a_project_may_add_users_and_override_an_existing_role
    result = merge(
      { roles: { pm: [], engineer: [] }, users: { matt: { role: "pm" } } },
      { users: { matt: { role: "engineer" }, sam: { role: "pm" } } }
    )
    assert_equal "engineer", result.config[:users][:matt][:role]
    assert_equal "pm", result.config[:users][:sam][:role]
    assert_equal :project, result.provenance[:users][:matt]
    assert_equal :project, result.provenance[:users][:sam]
  end

  def test_a_project_may_not_rewrite_any_other_field_on_a_globally_defined_user
    err = assert_raises(Riggs::Error) do
      merge({ roles: { pm: [] }, users: { matt: { role: "pm", memory_namespace: "team" } } },
            { users: { matt: { memory_namespace: "hijacked" } } })
    end
    assert_includes err.message, "matt"
    assert_includes err.message, "memory_namespace"
  end

  def test_a_new_project_user_may_set_every_field
    result = merge({ roles: { pm: [] } },
                   { users: { sam: { id: "sam", name: "Sam", role: "pm", memory_namespace: "sam_priv" } } })
    assert_equal "sam_priv", result.config[:users][:sam][:memory_namespace]
  end

  def test_provenance_marks_only_the_users_the_project_touched
    result = merge({ roles: { pm: [], engineer: [] },
                     users: { matt: { role: "pm" }, kim: { role: "engineer" } } },
                   { users: { matt: { role: "engineer" } } })
    assert_equal :project, result.provenance[:users][:matt]
    assert_equal :global, result.provenance[:users][:kim]
  end

  # The distinguishing case: mentioned but unchanged. Without this, the
  # "unless merged[name] == g[name]" guard could be deleted and the test above
  # would still pass.
  def test_restating_a_users_existing_role_does_not_claim_project_provenance
    result = merge({ roles: { pm: [] }, users: { matt: { role: "pm" } } },
                   { users: { matt: { role: "pm" } } })
    assert_equal :global, result.provenance[:users][:matt]
  end

  def test_a_user_naming_an_undefined_role_is_a_hard_error_listing_the_defined_ones
    err = assert_raises(Riggs::Error) do
      merge({ roles: { pm: [] } }, { users: { kim: { role: "client_reviewer" } } })
    end
    assert_includes err.message, "kim"
    assert_includes err.message, "client_reviewer"
    assert_includes err.message, "pm"
  end

  def test_a_user_may_name_a_built_in_role_that_no_config_defines
    result = merge({}, { users: { sam: { role: "viewer" } } })
    assert_equal "viewer", result.config[:users][:sam][:role]
  end

  def test_default_user_from_the_project_must_resolve_in_the_merged_user_set
    ok = merge({ users: { matt: { role: "pm" } } }, { default_user: "matt" })
    assert_equal "matt", ok.config[:default_user]
    assert_equal :project, ok.provenance[:default_user]

    err = assert_raises(Riggs::Error) { merge({ users: { matt: { role: "pm" } } }, { default_user: "ghost" }) }
    assert_includes err.message, "ghost"
  end

  # --- providers: override only, no credentials ---

  def test_a_project_may_override_fields_on_a_globally_defined_provider
    result = merge(
      { providers: { ollama: { type: "ollama", base_url: "http://a" } } },
      { providers: { ollama: { model: "llama3.2" } } }
    )
    assert_equal "ollama", result.config[:providers][:ollama][:type]
    assert_equal "http://a", result.config[:providers][:ollama][:base_url]
    assert_equal "llama3.2", result.config[:providers][:ollama][:model]
  end

  def test_a_project_naming_an_undefined_provider_is_a_hard_error_listing_the_defined_ones
    err = assert_raises(Riggs::Error) do
      merge({ providers: { mock: { type: "mock" } } }, { providers: { sneaky: { type: "anthropic" } } })
    end
    assert_includes err.message, "sneaky"
    assert_includes err.message, "mock"
  end

  def test_api_key_in_the_project_tier_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({ providers: { claude: { type: "anthropic" } } },
            { providers: { claude: { api_key: "sk-live-abc" } } })
    end
    assert_includes err.message, "api_key"
    assert_includes err.message, "claude"
    refute_includes err.message, "sk-live-abc"
  end

  # Banning api_key alone left four other doors open.
  def test_every_provider_field_outside_the_allowlist_is_a_hard_error
    [{ token: "t" }, { secret: "s" }, { password: "p" },
     { auth: { api_key: "sk-nested" } }, { type: "anthropic" }].each do |bad|
      err = assert_raises(Riggs::Error, "#{bad.keys.first} must be rejected") do
        merge({ providers: { claude: { type: "anthropic" } } }, { providers: { claude: bad } })
      end
      assert_includes err.message, bad.keys.first.to_s
    end
  end

  def test_a_plain_auth_string_is_still_permitted
    result = merge({ providers: { claude_cli: { type: "claude_cli" } } },
                   { providers: { claude_cli: { auth: "subscription" } } })
    assert_equal "subscription", result.config[:providers][:claude_cli][:auth]
  end

  # --- mcp_servers: merge, with provenance ---

  def test_a_project_may_add_mcp_servers_without_removing_global_ones
    result = merge(
      { mcp_servers: { context7: { command: "npx" }, honeybadger: { command: "npx" } } },
      { mcp_servers: { projectonly: { command: "./bin/mcp" } } }
    )
    assert_equal %i[context7 honeybadger projectonly].sort, result.config[:mcp_servers].keys.sort
    assert_equal :project, result.provenance[:mcp_servers][:projectonly]
    assert_equal :global, result.provenance[:mcp_servers][:context7]
  end

  def test_a_project_overriding_a_global_mcp_server_is_marked_project_provenance
    result = merge({ mcp_servers: { hb: { command: "npx" } } },
                   { mcp_servers: { hb: { command: "./evil" } } })
    assert_equal "./evil", result.config[:mcp_servers][:hb][:command]
    assert_equal :project, result.provenance[:mcp_servers][:hb]
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_config_merge.rb`
Expected: FAIL — `NameError: uninitialized constant Riggs::Config::Merge`

- [ ] **Step 3: Implement the merge**

Create `lib/riggs/config/merge.rb`:

```ruby
# frozen_string_literal: true

module Riggs
  module Config
    # Three merge algebras, deliberately not one. A lost provider is a billing
    # surprise, a lost MCP server is a missing tool, and a lost skill is a
    # silent capability change, so replace-or-error, merge-by-key and
    # merge-with-gate cannot share an implementation.
    module Merge
      # An ALLOWLIST, not a denylist. A denylist has to enumerate every
      # dangerous key in advance and is wrong the moment one is added -- and it
      # was already wrong once: an earlier draft banned sqlite_path and said
      # nothing about sqlite_memory, whose vector_path and memory_path go
      # straight into enable_load_extension/load_extension in
      # MemoryService#load_extensions!. That is arbitrary native code loaded
      # without touching the MCP approval this phase exists to build.
      PROJECT_KEYS = %i[default_user roles users providers mcp_servers].freeze

      # Same reasoning one level down: banning api_key alone left token,
      # secret, password and a nested auth: hash wide open.
      PROVIDER_FIELDS = %i[model base_url pricing relay_chain auth].freeze

      # On a user the global tier already defines, only the role may change.
      # Everything else -- id, name, github_username, memory_namespace -- is
      # the operator's own record of who someone is.
      USER_OVERRIDE_FIELDS = %i[role].freeze

      Merged = Struct.new(:config, :provenance, keyword_init: true)

      class << self
        # global_path and project_path default to a readable placeholder rather
        # than nil: they appear verbatim in every diagnostic, and a nil one
        # renders "role 'engineer' is defined in  and cannot be redefined",
        # which fails the two-file requirement precisely when someone is
        # debugging a merge.
        def call(global:, project:, global_path: "the global config",
                 project_path: "the project config")
          g = Identity.deep_symbolize(global || {})
          pr = Identity.deep_symbolize(project || {})
          return Merged.new(config: g, provenance: all_global(g)) if pr.empty?

          reject_unlisted_keys!(pr, global_path, project_path)

          config = g.dup
          prov = {}
          config[:default_user] = pr[:default_user] if pr.key?(:default_user)
          config[:roles], prov[:roles] = merge_roles(g[:roles], pr[:roles], global_path, project_path)
          config[:users], prov[:users] = merge_users(g[:users], pr[:users], project_path)
          config[:providers], prov[:providers] = merge_providers(g[:providers], pr[:providers], project_path)
          config[:mcp_servers], prov[:mcp_servers] = merge_by_key(g[:mcp_servers], pr[:mcp_servers])
          prov[:default_user] = pr.key?(:default_user) ? :project : :global

          validate_user_roles!(config, project_path)
          validate_default_user!(config, project_path)
          Merged.new(config: config, provenance: prov)
        end

        private

        def all_global(config)
          {
            roles: tier_map(config[:roles], :global), users: tier_map(config[:users], :global),
            providers: tier_map(config[:providers], :global),
            mcp_servers: tier_map(config[:mcp_servers], :global), default_user: :global
          }
        end

        def tier_map(hash, tier)
          (hash || {}).keys.to_h { |k| [k, tier] }
        end

        def reject_unlisted_keys!(project, global_path, project_path)
          unlisted = project.keys - PROJECT_KEYS
          return if unlisted.empty?

          raise Error, "#{project_path}: '#{unlisted.first}' may only be set in #{global_path} " \
                       "(a project may set: #{PROJECT_KEYS.map(&:to_s).sort.join(', ')})"
        end

        # Assignment is local, definition is global. A project may name a role
        # the global tier has never heard of; it may not change what a global
        # word means, so that 'engineer' reads the same in every repo.
        def merge_roles(global, project, global_path, project_path)
          g = global || {}
          pr = project || {}
          clash = pr.keys & g.keys
          unless clash.empty?
            raise Error, "role '#{clash.first}' is defined in #{global_path} and cannot be " \
                         "redefined by #{project_path}"
          end

          [g.merge(pr), tier_map(g, :global).merge(tier_map(pr, :project))]
        end

        def merge_by_key(global, project)
          g = global || {}
          pr = project || {}
          merged = g.merge(pr) { |_k, gv, pv| gv.is_a?(Hash) && pv.is_a?(Hash) ? gv.merge(pv) : pv }
          [merged, tier_map(g, :global).merge(tier_map(pr, :project))]
        end

        # A new user may describe itself fully; an existing one may only be
        # reassigned. Provenance is :project only for users the project
        # actually changed.
        def merge_users(global, project, project_path)
          g = global || {}
          pr = project || {}
          merged = g.dup
          prov = tier_map(g, :global)

          pr.each do |name, opts|
            fields = opts.is_a?(Hash) ? opts : {}
            if g.key?(name)
              extra = fields.keys - USER_OVERRIDE_FIELDS
              unless extra.empty?
                raise Error, "#{project_path}: user '#{name}' is defined globally, so only " \
                             "#{USER_OVERRIDE_FIELDS.map(&:to_s).join(', ')} may be overridden " \
                             "(got '#{extra.first}')"
              end

              merged[name] = g[name].merge(fields)
            else
              merged[name] = fields
            end
            # :project only when the value actually differs. Marking every
            # mentioned user :project would make R11.5 print "from
            # .riggs/config.yml" for a user the project merely restated.
            prov[name] = :project unless merged[name] == g[name]
          end

          [merged, prov]
        end

        # A repo must not carry secrets, and it must not be able to introduce a
        # provider riggs would otherwise not dispatch. It may retune one, and
        # only through the listed fields.
        def merge_providers(global, project, project_path)
          g = global || {}
          pr = project || {}
          unknown = pr.keys - g.keys
          unless unknown.empty?
            raise Error, "#{project_path} configures provider '#{unknown.first}' which is not defined " \
                         "globally (defined: #{g.keys.map(&:to_s).sort.join(', ')})"
          end

          pr.each do |name, opts|
            fields = opts.is_a?(Hash) ? opts : {}
            extra = fields.keys - PROVIDER_FIELDS
            unless extra.empty?
              raise Error, "provider '#{name}': '#{extra.first}' may not be set in #{project_path} " \
                           "(a project may set: #{PROVIDER_FIELDS.map(&:to_s).join(', ')}); " \
                           "credentials come from the environment"
            end

            # `auth` names a mode -- "subscription", "api", "none". Anything
            # that is not a String or Symbol is rejected: a Hash would smuggle
            # api_key back in under an allowlisted key (the check above only
            # looks one level down), and false/nil/1 are not mode names either,
            # so an allowlist of TYPES beats a denylist of them.
            next unless fields.key?(:auth)
            next if fields[:auth].is_a?(String) || fields[:auth].is_a?(Symbol)

            raise Error, "provider '#{name}': 'auth' must be a mode name, got #{fields[:auth].inspect}, " \
                         "in #{project_path}"
          end

          merge_by_key(g, pr)
        end

        def known_roles(config)
          (config[:roles] || {}).keys.map(&:to_s) | Identity::DEFAULT_ROLES.keys.map(&:to_s)
        end

        def validate_user_roles!(config, project_path)
          known = known_roles(config)
          (config[:users] || {}).each do |name, cfg|
            role = (cfg.is_a?(Hash) ? cfg[:role] : nil).to_s
            next if role.empty? || known.include?(role)

            raise Error, "#{project_path}: user '#{name}' names role '#{role}' which is not defined " \
                         "(defined: #{known.sort.join(', ')})"
          end
        end

        def validate_default_user!(config, project_path)
          name = config[:default_user].to_s
          return if name.empty?
          return if (config[:users] || {}).key?(name.to_sym)

          raise Error, "#{project_path}: default_user '#{name}' is not defined in either tier"
        end
      end
    end
  end
end
```

Add to `lib/riggs.rb`:

```ruby
require_relative "riggs/config/merge"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_config_merge.rb`
Expected: PASS, 14 runs, 0 failures.

- [ ] **Step 5: Mutation-verify the three hard errors**

For each, make the change, run the file, confirm the named test fails, revert, and paste the output:

A mutation must REMOVE the protection, not merely change how it is expressed.
Deleting a guard clause and leaving the `raise` behind it makes the raise
unconditional, so the test expecting an error still passes and proves nothing.

1. In `merge_roles`, delete the whole `unless clash.empty? ... end` block →
   `test_a_project_redefining_a_global_role_is_a_hard_error` must fail.
2. In `merge_providers`, delete the whole `unless unknown.empty? ... end`
   block (guard AND raise together) →
   `test_a_project_naming_an_undefined_provider_is_a_hard_error_listing_the_defined_ones`
   must fail.
3. Change `PROVIDER_FIELDS` to include `:api_key` →
   `test_api_key_in_the_project_tier_is_a_hard_error` must fail. Then change it
   to include `:token` → `test_every_provider_field_outside_the_allowlist_is_a_hard_error`
   must fail.
4. Change `PROJECT_KEYS` to include `:sqlite_memory` →
   `test_sqlite_memory_in_the_project_tier_is_a_hard_error` must fail. This is
   the one that was actually wrong in the first draft of this plan.
5. In `merge_users`, delete the whole `unless extra.empty? ... end` block →
   `test_a_project_may_not_rewrite_any_other_field_on_a_globally_defined_user`
   must fail.

- [ ] **Step 6: Run the full gate and commit**

```bash
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rubocop
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rake test
git add lib/riggs/config/merge.rb lib/riggs.rb test/test_config_merge.rb
git commit -m "Add Config::Merge with per-key tier algebras and provenance"
```

---

### Task 4: Wire `Identity` to the tiers

**Files:**
- Modify: `lib/riggs/identity.rb`
- Test: `test/test_identity_tiers.rb` (create)

**Interfaces:**
- Consumes: `Config::Resolver` (Task 2), `Config::Merge` (Task 3).
- Produces:
  - `Identity.resolved(cwd:, trust:, global_config:) -> Config::Merge::Merged` extended with `project_path`, `trusted`, `legacy`, `project_config_path`
  - `Identity.load_config(path = nil) -> Hash` — unchanged signature and return type
  - `Identity.config_path -> String | nil` — now the project config path, or the global one when there is no project tier

`load_config` is the choke point. Every production caller goes through it — `web/app.rb:33,96`, `engine.rb:17`, `config_store.rb:21`, and eight commands in `cli/commands.rb` via the private `load_config` helper at `:592` — as does every `hub_config:` in the test suite. Keeping its contract is what lets this task be small. Confirm the current list yourself with `grep -rn "load_config\|config_path" lib test` before starting; do not trust this sentence's count.

- [ ] **Step 1: Write the failing tests**

Create `test/test_identity_tiers.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestIdentityTiers < Minitest::Test
  def setup
    Riggs::Config::Resolver.reset_cache!
  end

  def teardown
    Riggs::Config::Resolver.reset_cache!
  end

  def sandbox
    Dir.mktmpdir do |dir|
      root = File.realpath(dir)
      trust = Riggs::Trust.new(path: File.join(root, "trust.yml"))
      global = File.join(root, "global.yml")
      File.write(global, Psych.dump(
                           "default_user" => "matt",
                           "roles" => { "pm" => %w[publish read_workflow] },
                           "users" => { "matt" => { "role" => "pm" } },
                           "providers" => { "mock" => { "type" => "mock" } }
                         ))
      yield(root, trust, global)
    end
  end

  def resolved(root, trust, global)
    Riggs::Identity.resolved(cwd: root, trust: trust, global_config: global)
  end

  def write_project(root, hash)
    FileUtils.mkdir_p(File.join(root, ".riggs"))
    File.write(File.join(root, ".riggs", "config.yml"), Psych.dump(hash))
  end

  def test_the_merged_config_is_the_global_tier_when_no_project_file_exists
    sandbox do |root, trust, global|
      r = resolved(root, trust, global)
      assert_equal "matt", r.config[:default_user]
      assert_equal root, r.project_path
    end
  end

  def test_a_trusted_project_tier_merges_and_carries_provenance
    sandbox do |root, trust, global|
      write_project(root, "default_user" => "sam", "users" => { "sam" => { "role" => "pm" } })
      trust.grant!(root)
      r = resolved(root, trust, global)
      assert_equal "sam", r.config[:default_user]
      assert_equal :project, r.provenance[:default_user]
      assert_equal :global, r.provenance[:users][:matt]
      assert_equal :project, r.provenance[:users][:sam]
    end
  end

  def test_an_untrusted_project_tier_contributes_nothing
    sandbox do |root, trust, global|
      write_project(root, "default_user" => "sam", "users" => { "sam" => { "role" => "pm" } })
      r = resolved(root, trust, global)
      assert_equal "matt", r.config[:default_user]
      refute r.trusted
    end
  end

  def test_identity_resolve_reads_a_project_added_user_after_trust
    sandbox do |root, trust, global|
      write_project(root, "users" => { "sam" => { "role" => "pm", "name" => "Sam" } })
      trust.grant!(root)
      cfg = resolved(root, trust, global).config
      identity = Riggs::Identity.resolve(cli_user: "sam", config: cfg)
      assert_equal "Sam", identity[:name]
      assert_includes identity[:permissions], "publish"
    end
  end

  def test_load_config_still_returns_a_plain_symbolized_hash
    sandbox do |root, trust, global|
      cfg = Riggs::Identity.load_config(nil, cwd: root, trust: trust, global_config: global)
      assert_kind_of Hash, cfg
      assert_equal "matt", cfg[:default_user]
    end
  end

  def test_load_config_with_an_explicit_path_still_reads_only_that_file
    sandbox do |root, _trust, _global|
      path = File.join(root, "standalone.yml")
      File.write(path, Psych.dump("default_user" => "solo", "users" => { "solo" => { "role" => "viewer" } }))
      cfg = Riggs::Identity.load_config(path)
      assert_equal "solo", cfg[:default_user]
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_identity_tiers.rb`
Expected: FAIL — `NoMethodError: undefined method 'resolved' for Riggs::Identity`

- [ ] **Step 3: Implement**

In `lib/riggs/identity.rb`, replace `CONFIG_CANDIDATES`, `config_path` and `load_config` with:

```ruby
    # Kept so an explicit path still reads exactly one file, which is what
    # ConfigStore and `load_config(path)` callers rely on.
    CONFIG_CANDIDATES = [".agent_hubrc", "./config/.agent_hubrc", "./config/agent_hubrc"].freeze

    Resolved = Struct.new(:config, :provenance, :project_path, :project_config_path,
                          :trusted, :legacy, keyword_init: true)

    def self.resolved(cwd: Dir.pwd, trust: nil, global_config: nil)
      # Resolve the real path first. Passing the nil-defaulted parameter
      # straight through made every production merge diagnostic name a
      # placeholder instead of the actual file -- the same defect as
      # config_path's nil, one method over.
      gc = global_config || Config::Resolver.global_config
      r = Config::Resolver.new(cwd: cwd, trust: trust, global_config: gc).resolve
      merged = Config::Merge.call(
        global: r.global, project: r.project,
        global_path: gc, project_path: r.project_config_path || r.project_path
      )
      Resolved.new(
        config: merged.config, provenance: merged.provenance, project_path: r.project_path,
        project_config_path: r.project_config_path, trusted: r.trusted, legacy: r.legacy
      )
    end

    # The path a human should edit for project-scoped settings. Falls through
    # to the global config when there is no TRUSTED project tier -- Resolver
    # returns nil for project_config_path on an untrusted path, so this can
    # never hand ConfigStore a file the resolver declined to open.
    #
    # `global_config` is resolved here, not defaulted to nil, because the body
    # calls File.exist? on it and every zero-argument caller would otherwise
    # raise TypeError -- including lib/riggs/web/app.rb:98.
    def self.config_path(cwd: Dir.pwd, trust: nil, global_config: nil)
      gc = global_config || Config::Resolver.global_config
      r = Config::Resolver.new(cwd: cwd, trust: trust, global_config: gc).resolve
      r.project_config_path || (File.exist?(gc) ? gc : nil)
    end

    # Unchanged contract: a symbolized hash. With no explicit path it is now
    # the merged two-tier result, which is why the eleven production call
    # sites and every hub_config: in the suite need no change.
    def self.load_config(path = nil, cwd: Dir.pwd, trust: nil,
                         global_config: nil)
      return load_file!(path) if path

      result = resolved(cwd: cwd, trust: trust, global_config: global_config)
      if result.config.empty?
        raise Error, "No riggs configuration found. Run 'riggs setup' to create ~/.riggs/config.yml."
      end

      result.config
    end

    def self.load_file!(path)
      raise Error, "Missing config at #{path}. Run 'riggs setup' first." unless File.exist?(path)

      raw = Psych.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
      deep_symbolize(raw)
    end
```

Add `require_relative "config/resolver"` and `require_relative "config/merge"` at the top of `identity.rb`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_identity_tiers.rb`
Expected: PASS, 6 runs.

- [ ] **Step 5: Convert `with_tmp_project` to write a GLOBAL tier**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rake test` and expect breakage.

`test_helper.rb`'s `write_hubrc` (`test/test_helper.rb:28-50`) writes an
`.agent_hubrc` containing `roles:` **and** `sqlite_path:`, then `with_tmp_project`
chdirs into that directory. Under the new rules that file is a *project* tier,
so: trusted → `sqlite_path` and every `roles` key are hard errors; untrusted →
the whole thing is ignored and `default_user: eng_bob` disappears. Either way
the suite breaks, and granting trust for the temp path makes it break sooner.
The first draft of this plan hand-waved this step; it is the real work.

The fix is to stop treating the fixture as a project tier at all:

```ruby
  def with_tmp_project
    Dir.mktmpdir("riggs-test") do |dir|
      Dir.mktmpdir("riggs-home") do |home|
        prior = ENV["RIGGS_HOME"]
        ENV["RIGGS_HOME"] = File.join(home, ".riggs")
        Riggs::Config::Resolver.reset_cache!
        Dir.chdir(dir) do
          FileUtils.mkdir_p("config/riggs/workflows")
          FileUtils.mkdir_p("config/riggs/skills/triage_v1")
          FileUtils.mkdir_p("db")
          write_global_config(dir)
          copy_example_workflow
          copy_skill
          Riggs::Storage.new(db_path: "./db/riggs.sqlite3").close
          Riggs::Trust.new.grant!(Riggs::Config::Resolver.project_path(dir))
          yield dir
        end
      ensure
        ENV["RIGGS_HOME"] = prior
        Riggs::Config::Resolver.reset_cache!
      end
    end
  end

  # The former write_hubrc content, moved to the tier that is allowed to hold
  # it. sqlite_path stays absolute-to-the-temp-project so each test keeps its
  # own database.
  def write_global_config(dir)
    FileUtils.mkdir_p(ENV.fetch("RIGGS_HOME"))
    File.write(File.join(ENV.fetch("RIGGS_HOME"), "config.yml"), <<~YAML)
      default_user: eng_bob
      users:
        pm_alice: { id: pm_alice, name: Alice PM, role: pm, memory_namespace: team_shared }
        eng_bob: { id: eng_bob, name: Bob Eng, role: engineer, memory_namespace: eng_bob_private }
        view_cara: { id: view_cara, name: Cara, role: viewer, memory_namespace: readonly }
      roles:
        pm: [edit_workflow, manage_skills, configure_memory, publish, read_workflow, inspect_run]
        engineer: [run_workflow, approve_gates, read_workflow, inspect_run, manage_mcp]
        viewer: [read_workflow, inspect_run]
      sqlite_path: "#{File.join(dir, 'db', 'riggs.sqlite3')}"
      providers:
        mock:
          type: mock
    YAML
  end
```

Trust is granted for the temp project because these tests exercise a project
riggs is meant to run in. Keep `write_hubrc` as a separate helper for the tests
that specifically exercise legacy `.agent_hubrc` handling and the new hard
errors — do not delete it.

**Do not** weaken `Config::Resolver` or `Config::Merge` to get the suite green.
If a test only passes with the gate loosened, that test is asserting the hole.
Report it instead.

Four existing tests are known to break. They are named here so you do not have
to discover them, and so a green suite that skipped one is visible:

- `test/test_cli.rb:21` `test_workflow_run_warns_when_mcp_config_is_broken` —
  appends `mcp_servers: totally_not_a_hash` to `.agent_hubrc`, now a project
  tier. Write it into the global config instead; `mcp_servers` is a permitted
  project key but the malformed-value warning is what the test is about.
- `test/test_config_store.rb:32` `test_merge_writes_backup_and_preserves_unrelated_keys` —
  expects an editor to add an **undefined** provider and to back up
  `.agent_hubrc`. Both assumptions now conflict with Task 9. Rewrite it against
  the global tier, or against a provider the global tier defines.
- `test/test_mcp.rb:13` and `test/test_mcp_manager.rb:53,70` — call
  `Manager.from_config` without the now-required `provenance:`. Add
  `provenance:` naming each server `:global`, which is what those tests mean.
- `test/test_mcp.rb:8-9` — assert `Client.from_config` returns nil. That method
  is deleted in Task 6; remove both assertions with it.

Any other test that writes `.agent_hubrc` mid-test to override config must move
that write to the global tier, or to `.riggs/config.yml` when the key is one a
project may set. List every test you touched in your report, including these.

Expected: 382+ runs, 0 failures.

- [ ] **Step 6: Run the full gate and commit**

```bash
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rubocop
PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec rake test
git add lib/riggs/identity.rb test/test_identity_tiers.rb test/test_helper.rb
git commit -m "Resolve Identity config through the two tiers"
```

---

### Task 5: Global skill and workflow roots

**Files:**
- Modify: `lib/riggs/skills/registry.rb:252-257`
- Modify: `lib/riggs/triggers.rb:23,32`
- Test: `test/test_tier_roots.rb` (create)

**Interfaces:**
- Consumes: `Config::Resolver.project_path`.
- Produces:
  - `SkillRegistry#default_roots` gains `~/.riggs/skills` in the middle.
  - `Triggers.find_workflows(text:, roots: nil)` and `Triggers.list_declared(roots: nil)` take an ordered list. The `dir:` keyword is kept as a single-root alias so existing callers and tests keep working.
  - Each entry `list_declared` returns gains a `:tier` key — `:project`, `:global`, or `:bundled`.

- [ ] **Step 1: Write the failing tests**

Create `test/test_tier_roots.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestTierRoots < Minitest::Test
  def with_riggs_home(path)
    prior = ENV["RIGGS_HOME"]
    ENV["RIGGS_HOME"] = path
    FileUtils.mkdir_p(path)
    Riggs::Config::Resolver.reset_cache!
    yield
  ensure
    ENV["RIGGS_HOME"] = prior
    Riggs::Config::Resolver.reset_cache!
  end

  def workflow_yaml(name)
    Psych.dump(
      "name" => name, "display_name" => name,
      "triggers" => [{ "type" => "keyword", "keywords" => ["shipit"] }],
      "steps" => [{ "id" => "a", "kind" => "prompt", "prompt" => "hi" }]
    )
  end

  def test_a_project_workflow_shadows_a_global_one_of_the_same_name
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      global = File.join(dir, "global")
      [project, global].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(project, "triage.yml"), workflow_yaml("triage"))
      File.write(File.join(global, "triage.yml"), workflow_yaml("triage"))
      File.write(File.join(global, "deploy.yml"), workflow_yaml("deploy"))

      found = Riggs::Triggers.list_declared(roots: [project, global])
      assert_equal %w[deploy triage], found.map { |w| w[:name] }.sort
      triage = found.find { |w| w[:name] == "triage" }
      assert_equal File.join(project, "triage.yml"), triage[:path]
      # Both roots here are explicit temp directories, so neither equals
      # Trust.home/workflows or the bundled path and tier_for reports :project
      # for both. Shadowing is what this test asserts; tier LABELLING is
      # asserted below against real roots, where the comparison is meaningful.
      assert_equal :project, triage[:tier]
    end
  end

  def test_tier_labels_the_real_global_and_bundled_roots
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        global = File.join(home, ".riggs", "workflows")
        FileUtils.mkdir_p(global)
        File.write(File.join(global, "deploy.yml"), workflow_yaml("deploy"))
        Dir.mktmpdir do |repo|
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            declared = Riggs::Triggers.list_declared
            assert_equal :global, declared.find { |w| w[:name] == "deploy" }[:tier]
            bundled = declared.find { |w| w[:name] == "example_triage" }
            assert_equal :bundled, bundled[:tier], "the third tier must label itself too"
          end
        end
      end
    end
  end

  def test_a_global_workflow_is_matchable_from_a_project_that_does_not_define_it
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      global = File.join(dir, "global")
      [project, global].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(global, "deploy.yml"), workflow_yaml("deploy"))

      matched = Riggs::Triggers.find_workflows(text: "please shipit now", roots: [project, global])
      assert_equal ["deploy"], matched.map { |w| w[:name] }
    end
  end

  def test_the_dir_keyword_still_works_as_a_single_root
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "solo.yml"), workflow_yaml("solo"))
      assert_equal ["solo"], Riggs::Triggers.list_declared(dir: dir).map { |w| w[:name] }
    end
  end

  def test_list_declared_stays_sorted_by_name_across_roots
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      global = File.join(dir, "global")
      [project, global].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(project, "zulu.yml"), workflow_yaml("zulu"))
      File.write(File.join(global, "alpha.yml"), workflow_yaml("alpha"))
      names = Riggs::Triggers.list_declared(roots: [project, global]).map { |w| w[:name] }
      assert_equal %w[alpha zulu], names, "output must not become root-order-dependent"
    end
  end

  def test_skill_roots_place_the_global_tier_between_project_and_bundled
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          Riggs::Trust.new.grant!(Riggs::Config::Resolver.project_path(repo))
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            roots = Riggs::SkillRegistry.new.send(:default_roots)
            assert_equal 3, roots.length
            assert_includes roots[0], File.join("config", "riggs", "skills")
            assert_equal File.join(home, ".riggs", "skills"), roots[1]
          end
        end
      end
    end
  end

  def test_the_bundled_skill_root_actually_exists
    root = Riggs::SkillRegistry.new.send(:default_roots).last
    assert File.directory?(root), "bundled skill root #{root} must exist; ../../ resolved to lib/config/"
  end

  # R11.9 #1a: an untrusted repo contributes nothing, and resolution falls
  # through rather than failing.
  def test_an_untrusted_project_contributes_no_skill_or_workflow_root
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          FileUtils.mkdir_p(File.join(repo, "config", "riggs", "workflows"))
          File.write(File.join(repo, "config", "riggs", "workflows", "sneaky.yml"), workflow_yaml("sneaky"))
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            assert_equal 2, Riggs::SkillRegistry.new.send(:default_roots).length
            refute_includes Riggs::Triggers.list_declared.map { |w| w[:name] }, "sneaky"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `PATH="/Users/matt/.local/share/mise/shims:$PATH" bundle exec ruby -Itest test/test_tier_roots.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :roots`

- [ ] **Step 3: Implement**

In `lib/riggs/skills/registry.rb`, replace `default_roots`:

```ruby
    # The project root is nil unless the path is trusted, so an untrusted repo
    # contributes no skills and resolution falls through to global and bundled.
    # RIGGS_HOME rather than Dir.home so config, trust, skills and workflows
    # all name the same global install.
    def default_roots
      [
        Config::Resolver.new.project_roots[:skills],
        File.join(Trust.home, "skills"),
        # Three levels, not two. __dir__ here is lib/riggs/skills, so the
        # existing "../../" resolves to lib/config/riggs/skills -- a directory
        # that has never existed, which is why no bundled skill has ever
        # loaded. Pre-existing bug, fixed here because this task rewrites this
        # exact method and shipping the tier list with a dead entry in it would
        # make the new global tier look broken for the same reason.
        File.expand_path("../../../config/riggs/skills", __dir__)
      ].compact
    end
```

In `lib/riggs/triggers.rb`, replace both methods:

```ruby
    # Ordered roots, first match by workflow NAME wins. Shadowing rather than
    # merging: a project triage.yml replaces the global one instead of both
    # appearing. A global workflow with a keyword trigger fires in every repo,
    # which is the point of the tier -- so every entry reports which tier it
    # came from, or an operator cannot explain a match against a file that is
    # not in the repo.
    def self.default_roots
      [
        Config::Resolver.new.project_roots[:workflows],
        File.join(Trust.home, "workflows"),
        File.expand_path("../../config/riggs/workflows", __dir__)
      ].compact
    end

    # Tier is derived from the root's own path, not its index: default_roots
    # compacts away an untrusted project root, so index 0 is not always the
    # project and a positional rule would relabel the global tier as project
    # for exactly the repos where that claim is most misleading.
    #
    # Exact comparison of expanded paths, not start_with?. A prefix test calls
    # /tmp/riggs-home-evil "global" when RIGGS_HOME=/tmp/riggs-home, and calls
    # a project living under RIGGS_HOME global too.
    def self.tier_for(dir)
      expanded = File.expand_path(dir.to_s)
      return :global if expanded == File.expand_path(File.join(Trust.home, "workflows"))
      return :bundled if expanded == File.expand_path("../../config/riggs/workflows", __dir__)

      :project
    end

    def self.each_declared(roots)
      seen = {}
      Array(roots).compact.each do |dir|
        tier = tier_for(dir)
        Dir.glob(File.join(dir, "*.yml")).sort.each do |path|
          workflow = Workflow::Loader.load(path: path)
          name = workflow[:name].to_s
          next if seen.key?(name)

          seen[name] = true
          yield(workflow, path, tier)
        rescue WorkflowError
          next
        end
      end
    end

    # Carries the tier out with each match. The spec requires BOTH triggers:list
    # and triggers:match to report it, and discarding it here left
    # triggers_match unable to explain why a workflow that is not in the repo
    # matched -- which is the case the tier exists to explain.
    def self.find_workflows(text:, dir: nil, roots: nil)
      out = []
      each_declared(roots || (dir ? [dir] : default_roots)) do |workflow, _path, tier|
        out << workflow.merge(tier: tier) if match(workflow, text: text)
      end
      out
    end

    def self.list_declared(dir: nil, roots: nil)
      declared = []
      each_declared(roots || (dir ? [dir] : default_roots)) do |workflow, path, tier|
        declared << {
          name: workflow[:name], display_name: workflow[:display_name], path: path, tier: tier,
          triggers: Array(workflow[:triggers]).map { |t| summarize_trigger(t) }
        }
      end
      # The existing method sorts by name before returning (triggers.rb:45).
      # Dropping it makes output root-order-dependent and breaks callers that
      # rely on a stable list.
      declared.sort_by { |w| w[:name].to_s }
    end
```

Keep the rest of `list_declared`'s existing return shape intact — read the current method before editing and preserve every key it already produces.

In `lib/riggs/cli/commands.rb`, **both** `triggers_list` (`:193`) and
`triggers_match` (`:179`) print each workflow; add the tier to both lines. The
match path is the one that most needs it — that is where a workflow which is
not in the repo appears without explanation.

**Route every workflow caller through the same root list.** This is the point
of the task, not a tidy-up. Enumeration and loading are separate functions in
this codebase with separately hardcoded paths, and they diverged — gating
`Triggers.default_roots` while `load_workflow` keeps its own literal leaves the
*execution* path open. Add:

```ruby
    # The one place a workflow NAME becomes a file path. Before this,
    # CLI#load_workflow and WebApp#workflow_path each hardcoded
    # config/riggs/workflows, and web/app.rb reached them from show, run and
    # resume -- so gating default_roots governed what `triggers:list` displayed
    # and nothing that executed. First root wins, matching skill resolution.
    def self.find_path(name, roots: nil)
      # A name is a NAME, not a path. File.join(dir, "../../etc/x.yml") escapes
      # every trusted root, and `name` arrives from `riggs workflow:run NAME`
      # and from the /api/workflows/:name/run route -- so this is remote path
      # traversal, not just a local footgun.
      safe = safe_name(name)
      return nil if safe.nil?

      Array(roots || default_roots).compact.each do |dir|
        candidate = File.join(dir, "#{safe}.yml")
        next unless File.exist?(candidate)
        # The syntactic guard stops `../`; it does not stop a SYMLINK inside
        # the root pointing out of it. Containment is checked on real paths.
        next unless contained?(candidate, dir)

        return candidate
      end
      nil
    end

    def self.contained?(candidate, dir)
      real_dir = File.realpath(dir)
      File.realpath(candidate).start_with?("#{real_dir}#{File::SEPARATOR}")
    rescue SystemCallError
      false
    end
```

Then replace **every** caller. Enumerate them mechanically rather than by
memory — routing one helper and missing the rest is the exact error this task
has now made twice, and both times the missed route was the one that executes:

```bash
grep -rn "config/riggs/workflows\|workflows_dir\|workflow_path\|Triggers\." lib
```

Against the current tree that is **nine** sites in two files:

| site | change |
| --- | --- |
| `cli/commands.rb:609` `load_workflow` | `path = Triggers.find_path(name)`, delete both hardcoded paths |
| `web/app.rb:571` `workflow_path` | delete the method; callers use `Triggers.find_path(name)` |
| `web/app.rb:278` HTML show | `Triggers.find_path(name)` |
| `web/app.rb:325` API show | `Triggers.find_path(name)` |
| `web/app.rb:473` HTML run | `Triggers.find_path(name)` |
| `web/app.rb:532` resume | `Triggers.find_path(workflow_name)` |
| `web/app.rb:550` `list_workflows` | delete the method; callers use `Triggers.list_declared.map { \|w\| w[:name] }` |
| `web/app.rb:558` `workflows_dir` | delete the method |
| `web/app.rb:170`, `:230` | `Triggers.list_declared` with no `dir:` |
| `web/app.rb:566` | `Triggers.find_workflows(text: query)` with no `dir:` |
| `cli/commands.rb:227` `workflow_new` | see below — it **writes**, so it needs the guard and a root, not `find_path` |

`workflow:new` is the site three review rounds missed because it is a writer
rather than a reader. It builds `"./config/riggs/workflows/#{name}.yml"` from
an unvalidated `NAME`, `mkdir_p`s its dirname, writes it, and reloads it at
`:243`. `riggs workflow:new ../../../../tmp/x` creates directories and writes a
file outside every root. Add to `Triggers`:

```ruby
    # Where a writer puts a new workflow. Separate from find_path because
    # creating a file is not looking one up: there is exactly one correct
    # destination, and it is the project's own root whether or not anything
    # is there yet.
    def self.project_workflows_dir
      File.join(Config::Resolver.project_path, "config", "riggs", "workflows")
    end

    def self.safe_name(name)
      base = File.basename(name.to_s)
      return nil if base.empty? || base != name.to_s || base.start_with?(".")

      base
    end
```

`find_path` uses `safe_name` too, so the guard has one definition. `workflow_new`
becomes `name = Triggers.safe_name(name) or abort "❌ Invalid workflow name"`,
then writes into `Triggers.project_workflows_dir`.

`workflow_path` and `workflows_dir` must both be **gone**, not merely unused —
a private helper that still resolves an untrusted path is a bypass waiting for
its next caller. Verify:

```bash
grep -rn "config/riggs/workflows" lib
grep -rn "workflow_path\|workflows_dir\|list_workflows" lib
```

The first must show hits only inside `Triggers.default_roots`,
`Triggers.project_workflows_dir`, and `CLI::Setup` — setup legitimately
*creates* the directory, and `project_workflows_dir` is where a writer puts a
new file. Anything else is a route that escaped the resolver. The second must
show no hits at all. Paste both outputs in your report.

**Add these tests** to `test/test_tier_roots.rb`, because 1a and 1b in the spec
are deliberately separate assertions:

```ruby
  def test_an_untrusted_project_workflow_is_not_findable_by_name
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          FileUtils.mkdir_p(File.join(repo, "config", "riggs", "workflows"))
          File.write(File.join(repo, "config", "riggs", "workflows", "sneaky.yml"), workflow_yaml("sneaky"))
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            assert_nil Riggs::Triggers.find_path("sneaky"),
                       "loading is a different path from listing; both must be gated"
          end
        end
      end
    end
  end

  def test_a_trusted_project_workflow_is_findable_by_name
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          FileUtils.mkdir_p(File.join(repo, "config", "riggs", "workflows"))
          path = File.join(repo, "config", "riggs", "workflows", "mine.yml")
          File.write(path, workflow_yaml("mine"))
          Riggs::Trust.new.grant!(Riggs::Config::Resolver.project_path(repo))
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            assert_equal path, Riggs::Triggers.find_path("mine")
          end
        end
      end
    end
  end
```

- [ ] **Step 4: Verify pass, then full suite**

Run the file, then `bundle exec rake test`.

- [ ] **Step 5: Commit**

```bash
git add lib/riggs/skills/registry.rb lib/riggs/triggers.rb lib/riggs/cli/commands.rb \
        lib/riggs/web/app.rb test/test_tier_roots.rb test/test_web_app.rb
git commit -m "Route every workflow lookup through one trust-gated resolver"
```

Before committing, re-derive this file list from `git status --short` rather
than trusting the line above. A commit block that omits a file the task edited
is how the web-route fix would silently not ship.

---

### Task 6: Gate project-declared MCP servers

**Files:**
- Modify: `lib/riggs/mcp/manager.rb:79-93`
- Create: `lib/riggs/mcp/approval.rb`
- Test: `test/test_mcp_approval.rb`

**Interfaces:**
- Consumes: `Trust` (Task 1), provenance from `Identity.resolved` (Task 4).
- Produces:
  - `Manager.from_config(servers, provenance: {}, trust: nil, project_path: nil, interactive: false)`
  - `MCP::Approval.redact(command, args) -> String` — the display string
  - `MCP::NotApproved < Error`

`Manager#client_for` is the single place a configured name becomes a spawned process (`Client.new` at `manager.rb:86`, `Open3.popen2` at `client.rb:35`). The gate goes there and nowhere else.

- [ ] **Step 1: Write the failing tests**

Create `test/test_mcp_approval.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestMcpApproval < Minitest::Test
  SERVERS = {
    global_one: { command: "echo", args: %w[global] },
    project_one: { command: "echo", args: %w[project] }
  }.freeze
  PROV = { global_one: :global, project_one: :project }.freeze

  def manager(trust, interactive: false)
    Riggs::MCP::Manager.from_config(
      SERVERS, provenance: PROV, trust: trust, project_path: "/repo", interactive: interactive
    )
  end

  # Trust is granted for /repo because approve_mcp! now requires it -- the two
  # gates are separate and approval presumes the first one already passed.
  def with_trust
    Dir.mktmpdir do |dir|
      trust = Riggs::Trust.new(path: File.join(dir, "trust.yml"))
      trust.grant!("/repo")
      yield trust
    end
  end

  def test_a_globally_defined_server_needs_no_approval
    with_trust do |trust|
      refute_nil manager(trust).send(:client_for, "global_one")
    end
  end

  def test_an_unapproved_project_server_raises_rather_than_spawning
    with_trust do |trust|
      err = assert_raises(Riggs::MCP::NotApproved) { manager(trust).send(:client_for, "project_one") }
      assert_includes err.message, "project_one"
      assert_includes err.message, "riggs mcp:approve project_one"
    end
  end

  def test_an_approved_project_server_spawns
    with_trust do |trust|
      trust.approve_mcp!("/repo", "project_one", Riggs::Trust.digest(command: "echo", args: %w[project]))
      refute_nil manager(trust).send(:client_for, "project_one")
    end
  end

  # The client must be built with the RESOLVED path, or popen2 re-consults
  # PATH at spawn time and can exec a different binary under this approval.
  def test_an_approved_client_is_constructed_with_the_resolved_executable
    with_trust do |trust|
      trust.approve_mcp!("/repo", "project_one", Riggs::Trust.digest(command: "echo", args: %w[project]))
      client = manager(trust).send(:client_for, "project_one")
      command = client.instance_variable_get(:@command)
      assert command.start_with?("/"), "expected an absolute resolved path, got #{command.inspect}"
      assert_equal Riggs::Trust.resolve_executable("echo"), command
    end
  end

  # The one test in this file that actually reaches Open3. Every other
  # assertion stops at Client construction, which cannot distinguish "the gate
  # allowed it" from "the gate allowed it and the spawn would have failed".
  def test_an_unapproved_server_never_reaches_open3
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "spawned-4c1a")
      trust = Riggs::Trust.new(path: File.join(dir, "trust.yml"))
      trust.grant!("/repo")
      cfg = { evil: { command: "/bin/sh", args: ["-c", "touch #{marker}"] } }
      mgr = Riggs::MCP::Manager.from_config(cfg, provenance: { evil: :project },
                                            trust: trust, project_path: "/repo")
      assert_raises(Riggs::MCP::NotApproved) { mgr.list_tools }
      refute File.exist?(marker), "an unapproved server must never be spawned"
    end
  end

  def test_an_approved_server_does_reach_open3
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "spawned-9f2a")
      trust = Riggs::Trust.new(path: File.join(dir, "trust.yml"))
      trust.grant!("/repo")
      cfg = { ok: { command: "/bin/sh", args: ["-c", "touch #{marker}; exec cat"] } }
      digest = Riggs::Trust.digest(command: Riggs::Trust.resolve_executable("/bin/sh"),
                                   args: cfg[:ok][:args], env: {})
      trust.approve_mcp!("/repo", "ok", digest)
      mgr = Riggs::MCP::Manager.from_config(cfg, provenance: { ok: :project },
                                            trust: trust, project_path: "/repo")
      mgr.send(:client_for, "ok").start!
      assert File.exist?(marker), "an approved server must actually spawn; otherwise the gate proves nothing"
    ensure
      mgr&.close
    end
  end

  # End to end: approve under one PATH, then make the same name resolve to a
  # different binary. The stale approval must not carry over.
  def test_an_approval_does_not_survive_the_name_resolving_elsewhere
    Dir.mktmpdir do |dir|
      %w[a b].each do |sub|
        FileUtils.mkdir_p(File.join(dir, sub))
        bin = File.join(dir, sub, "swapmcp")
        File.write(bin, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, bin)
      end
      trust = Riggs::Trust.new(path: File.join(dir, "trust.yml"))
      trust.grant!("/repo")
      servers = { swap: { command: "swapmcp", args: [], env: { "PATH" => File.join(dir, "a") } } }
      prov = { swap: :project }
      build = lambda do |path_dir|
        cfg = { swap: { command: "swapmcp", args: [], env: { "PATH" => path_dir } } }
        Riggs::MCP::Manager.from_config(cfg, provenance: prov, trust: trust, project_path: "/repo")
      end
      trust.approve_mcp!("/repo", "swap", Riggs::Trust.digest(**servers[:swap]))
      refute_nil build.call(File.join(dir, "a")).send(:client_for, "swap")
      assert_raises(Riggs::MCP::NotApproved) { build.call(File.join(dir, "b")).send(:client_for, "swap") }
    end
  end

  def test_a_changed_command_revokes_the_approval
    with_trust do |trust|
      trust.approve_mcp!("/repo", "project_one", Riggs::Trust.digest(command: "echo", args: %w[old]))
      assert_raises(Riggs::MCP::NotApproved) { manager(trust).send(:client_for, "project_one") }
    end
  end

  # R11.4: a prompt nobody can answer is a hang. Asserting only that an error
  # is raised would pass an implementation that calls $stdin.gets, gets EOF,
  # and then raises -- which still blocks a scheduled job whose stdin is a pipe
  # nobody writes to. So assert stdin was never READ.
  def test_a_non_interactive_context_never_reads_stdin
    with_trust do |trust|
      original = $stdin
      probe = Object.new
      def probe.gets = raise("stdin was read in a non-interactive context")
      def probe.tty? = false
      $stdin = probe
      assert_raises(Riggs::MCP::NotApproved) do
        manager(trust, interactive: false).send(:client_for, "project_one")
      end
    ensure
      $stdin = original
    end
  end

  # Fail closed: a Manager that cannot say where a server came from must refuse.
  def test_a_manager_built_without_provenance_refuses_to_spawn
    with_trust do |trust|
      mgr = Riggs::MCP::Manager.from_config(SERVERS, provenance: {}, trust: trust, project_path: "/repo")
      assert_raises(Riggs::MCP::NotApproved) { mgr.send(:client_for, "project_one") }
    end
  end

  def test_from_config_requires_provenance
    assert_raises(ArgumentError) { Riggs::MCP::Manager.from_config(SERVERS) }
  end

  # Every other test here builds a flat PROV by hand, which agrees with the
  # code by construction. This one takes the shape Identity.resolved actually
  # produces -- provenance keyed by SECTION -- and proves the call sites index
  # into :mcp_servers rather than passing the whole hash, which would make
  # every lookup miss and fail every server closed, including global ones.
  def test_provenance_from_identity_resolved_has_the_shape_the_gate_indexes
    Dir.mktmpdir do |dir|
      trust = Riggs::Trust.new(path: File.join(dir, "trust.yml"))
      global = File.join(dir, "global.yml")
      File.write(global, Psych.dump("mcp_servers" => { "ctx" => { "command" => "echo" } }))
      resolved = Riggs::Identity.resolved(cwd: dir, trust: trust, global_config: global)

      assert_equal :global, resolved.provenance[:mcp_servers][:ctx]
      mgr = Riggs::MCP::Manager.from_config(
        resolved.config[:mcp_servers], provenance: resolved.provenance[:mcp_servers],
        trust: trust, project_path: dir
      )
      refute_nil mgr.send(:client_for, "ctx")
    end
  end

  # The gate raising is worthless if the caller eats it.
  def test_not_approved_escapes_list_tools_rather_than_becoming_an_empty_list
    with_trust do |trust|
      assert_raises(Riggs::MCP::NotApproved) { manager(trust).list_tools }
    end
  end

  # R11.9 7b. A regression tripwire, NOT a proof: it matches a string pattern,
  # so it will miss `Client.send(:new, ...)`, `Client.new(**cfg)`, an aliased
  # constant, or a factory, and it will fire on a legitimate in-process
  # construction. Its job is to make a future `MCP::Client.new` in lib/ fail
  # loudly enough that someone thinks about provenance. The real audit is the
  # spec's route list, done by reading.
  def test_no_config_driven_client_construction_exists_outside_the_manager
    refute Riggs::MCP::Client.respond_to?(:from_config),
           "Client.from_config builds a client from config with no approval; it must not exist"
    offenders = Dir.glob(File.expand_path("../lib/**/*.rb", __dir__)).select do |f|
      next false if f.end_with?("mcp/manager.rb")

      File.read(f).match?(/MCP::Client\.new|Client\.new\(command:/)
    end
    assert_empty offenders, "only Manager#client_for may construct an MCP::Client from configuration"
  end

  def test_an_interactive_context_that_is_declined_still_raises
    with_trust do |trust|
      fake = StringIO.new("n\n")
      original = $stdin
      $stdin = fake
      assert_raises(Riggs::MCP::NotApproved) do
        manager(trust, interactive: true).send(:client_for, "project_one")
      end
      refute trust.mcp_approved?("/repo", "project_one",
                                 Riggs::Trust.digest(command: "echo", args: %w[project]))
    ensure
      $stdin = original
    end
  end

  def test_an_interactive_context_that_is_accepted_records_the_approval
    with_trust do |trust|
      original = $stdin
      $stdin = StringIO.new("y\n")
      refute_nil manager(trust, interactive: true).send(:client_for, "project_one")
      assert trust.mcp_approved?("/repo", "project_one",
                                 Riggs::Trust.digest(command: "echo", args: %w[project]))
    ensure
      $stdin = original
    end
  end

  def test_the_display_string_redacts_secret_bearing_flags
    shown = Riggs::MCP::Approval.redact("npx", ["-y", "hb-mcp", "--token", "sk-live-abc123",
                                                "--api-key=sk-xyz", "--verbose"])
    refute_includes shown, "sk-live-abc123"
    refute_includes shown, "sk-xyz"
    assert_includes shown, "--token"
    assert_includes shown, "--verbose"
    assert_includes shown, "[redacted]"
  end

  def test_redaction_leaves_ordinary_arguments_alone
    shown = Riggs::MCP::Approval.redact("npx", %w[-y hb-mcp --port 8080])
    assert_includes shown, "8080"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Expected: FAIL — `NameError: uninitialized constant Riggs::MCP::NotApproved`

- [ ] **Step 3: Implement**

Create `lib/riggs/mcp/approval.rb`:

```ruby
# frozen_string_literal: true

module Riggs
  module MCP
    class NotApproved < Error; end

    # Rendering a command for a human to approve is a leak path: a secret
    # passed in argv would land in the terminal and in scrollback. This
    # redacts the common shape -- a value following a secret-bearing flag, in
    # either `--flag value` or `--flag=value` form. It is a heuristic and
    # cannot catch a bare positional secret; MCP configs are documented to
    # pass secrets by environment variable name instead.
    module Approval
      SECRET_FLAG = /\A--?[\w-]*(key|token|secret|password|credential)[\w-]*\z/i
      SECRET_INLINE = /\A(--?[\w-]*(key|token|secret|password|credential)[\w-]*)=(.+)\z/i
      REDACTED = "[redacted]"

      def self.redact(command, args)
        out = []
        redact_next = false
        Array(args).map(&:to_s).each do |arg|
          if redact_next
            out << REDACTED
            redact_next = false
          elsif (m = SECRET_INLINE.match(arg))
            out << "#{m[1]}=#{REDACTED}"
          else
            redact_next = SECRET_FLAG.match?(arg)
            out << arg
          end
        end
        ([command.to_s] + out).join(" ")
      end
    end
  end
end
```

In `lib/riggs/mcp/manager.rb`, extend the constructor and gate `client_for`:

```ruby
      # `provenance:` is REQUIRED, with no default. A caller that forgets it
      # then gets an ArgumentError at construction rather than an ungated spawn
      # later -- which is what a default of {} bought the first draft of this
      # plan. Ruby enforces the thing a code comment cannot.
      def self.from_config(servers, provenance:, trust: nil, project_path: nil, interactive: false)
        return new({}, provenance: {}) if servers.nil? || servers.empty?

        new(Identity.deep_symbolize(servers), provenance: provenance, trust: trust,
            project_path: project_path, interactive: interactive)
      end

      def initialize(configs = {}, provenance: {}, trust: nil, project_path: nil, interactive: false)
        @configs = configs.transform_keys(&:to_s)
        @provenance = (provenance || {}).transform_keys(&:to_s)
        @trust = trust
        @project_path = project_path
        @interactive = interactive
        @clients = {}
      end
```

and, inside `client_for`, replace the `Client.new` construction with:

```ruby
        command = ensure_approved!(key, cfg)
        client = Client.new(command: command, args: cfg[:args] || [], env: cfg[:env] || {})
```

`ensure_approved!` returns the command to spawn: the **resolved absolute path**
for a project-declared server, and the configured command unchanged for a
global one. Approval runs in `client_for`, but `Open3.popen2` runs later in
`Client#start!` (`lib/riggs/mcp/client.rb:35`) — so handing `Client` the
original bare name would leave a window where `PATH` changes and a different
binary runs under a valid approval. Passing the resolved path removes the race
rather than detecting it: `popen2` execs exactly the file that was digested.

with:

```ruby
      # The one place a configured name becomes a spawned process. A server
      # the global tier defined is the operator's own; one a repo introduced
      # is not, and is approved separately from the directory itself so a
      # later commit cannot add a command under an existing trust grant.
      #
      # FAILS CLOSED. The first draft returned early when provenance, trust or
      # project_path was missing, so any Manager built without them -- and
      # there are four from_config call sites in commands.rb alone
      # (338, 383, 516, 535) -- spawned project servers ungated. A construction
      # that cannot answer "did a repo introduce this?" must refuse, not
      # assume no.
      def ensure_approved!(name, cfg)
        # Resolve for BOTH tiers. A global server spawned by bare name still
        # re-consults PATH inside popen2, so "the resolved path is what gets
        # spawned" would have been false for exactly the servers the operator
        # trusts most. Resolution is not an approval; it is just naming the
        # file precisely.
        resolved = Trust.resolve_executable(cfg[:command], env: cfg[:env] || {})
        return resolved if @provenance[name] == :global

        unless @provenance.key?(name)
          raise NotApproved, "MCP server '#{name}' has no recorded tier. Build the Manager with " \
                             "provenance: from Identity.resolved so approval can be decided."
        end
        unless @trust && @project_path
          raise NotApproved, "MCP server '#{name}' is project-declared but this Manager was built " \
                             "without trust:/project_path:, so approval cannot be checked."
        end

        # Digest the path ALREADY resolved above, not the bare command -- which
        # would make Trust.digest resolve a second time, and a filesystem or
        # PATH change between the two calls could approve binary B while
        # spawning binary A. One resolution, used for both.
        digest = Trust.digest(command: resolved, args: cfg[:args] || [], env: cfg[:env] || {})
        return resolved if @trust.mcp_approved?(@project_path, name, digest)
        return resolved if @interactive && prompt_and_record!(name, cfg, digest)

        raise NotApproved, "MCP server '#{name}' is declared by this project and is not approved.\n" \
                           "  #{Approval.redact(cfg[:command], cfg[:args] || [])}\n" \
                           "Run: riggs mcp:approve #{name}"
      end

      def prompt_and_record!(name, cfg, digest)
        warn "⚠ project declares MCP server '#{name}'"
        warn "  #{Approval.redact(cfg[:command], cfg[:args] || [])}"
        warn "  approve? [y/N]"
        answer = $stdin.gets.to_s.strip.downcase
        return false unless %w[y yes].include?(answer)

        @trust.approve_mcp!(@project_path, name, digest)
        true
      end
```

Add `require_relative "approval"` and `require_relative "../trust"` at the top of `manager.rb`.

**Delete `MCP::Client.from_config` entirely** (`lib/riggs/mcp/client.rb:23-29`).
It builds a client straight from a servers hash with no provenance and no
approval, and it has **no callers in `lib/`** — only `test/test_mcp.rb:8-9`,
asserting it returns nil on empty input. It is dead config-driven API whose only
remaining function is to be a way around the gate. Remove those two assertions
with it.

`Manager.wrap_client` and `Client.new` stay public. Their caller is `GraphEngine`
(`lib/riggs/workflow/graph_engine.rb:29`) injecting an object in-process, not
reading a repository. Add a comment on `wrap_client` recording that it performs
no approval and must never be reachable from configuration.

**`NotApproved` must not be swallowed.** `Manager#list_tools` wraps each server
in `rescue StandardError => e; warn ...; []` (`manager.rb:46`), and
`NotApproved < Riggs::Error < StandardError` — so the gate raises, the rescue
eats it, and the run continues with an empty tool list and a warning nobody
reads. That is the Phase 10 lesson exactly: a raise is not a guard if a relay
swallows it. Add, **before** the generic rescue in `list_tools` and in every
other method that rescues broadly around `client_for`:

```ruby
        rescue NotApproved
          raise
```

Audit them: `grep -n "rescue StandardError" lib/riggs/mcp/manager.rb`. Every
one that can reach `client_for` needs the re-raise. R11.4 requires an error the
operator sees, and a warning that returns `[]` is not one.

**There are four `Manager.from_config` call sites, not two** — `commands.rb:338`,
`383`, `516`, `535`. Update every one to pass `trust:` and `project_path:` from
`Identity.resolved`, plus `interactive: $stdin.tty?`, and — critically —
`provenance: resolved.provenance[:mcp_servers]`, **not** `resolved.provenance`.

`Merge` returns provenance keyed by section (`{roles:, users:, providers:,
mcp_servers:, default_user:}`), while `ensure_approved!` indexes it by server
name. Passing the whole hash makes every lookup miss, so `@provenance.key?(name)`
is false and the fail-closed branch raises `NotApproved` for **every** server,
including global ones. The direct Manager tests hide this because they build a
flat `PROV` by hand. Add a test that constructs the Manager from a real
`Identity.resolved` so the shapes are checked against each other, not against a
fixture that agrees with the code by construction.

The web app and trigger paths pass `interactive: false`. Verify with:

```bash
grep -rn "Manager.from_config" lib test
```

Every hit must pass `provenance:`. The required keyword makes a miss an
immediate `ArgumentError`, so a forgotten site cannot ship silently — but check
anyway, because a site you never exercise in a test is a site Ruby never
reaches.

- [ ] **Step 4: Verify pass, then full suite**

- [ ] **Step 5: Mutation-verify the gate**

Change `return unless @provenance[name] == :project` to `return`.
`test_an_unapproved_project_server_raises_rather_than_spawning` MUST fail. Revert, paste output.

- [ ] **Step 6: Commit**

```bash
git add lib/riggs/mcp/approval.rb lib/riggs/mcp/manager.rb lib/riggs/mcp/client.rb \
        test/test_mcp_approval.rb test/test_mcp.rb test/test_mcp_manager.rb
git commit -m "Gate project-declared MCP servers behind per-server approval"
```

`client.rb` is in the list because Task 6 deletes `MCP::Client.from_config` from
it; `test_mcp.rb` and `test_mcp_manager.rb` because they assert on that method
and call `from_config` without `provenance:`. Re-derive the list from
`git status --short` before committing.

---

### Task 7: Two-tier `riggs setup`

**Files:**
- Modify: `lib/riggs/cli/commands.rb:44-137`
- Test: `test/test_setup_tiers.rb`

**Interfaces:**
- Consumes: `Trust`, `Config::Resolver`.
- Produces: `riggs setup` with no new flags, ensuring both tiers per artifact.

- [ ] **Step 1: Write the failing tests**

Create `test/test_setup_tiers.rb` covering exactly the spec's tests 13–16:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestSetupTiers < Minitest::Test
  def setup
    Riggs::Config::Resolver.reset_cache!
  end

  def teardown
    Riggs::Config::Resolver.reset_cache!
  end

  def run_setup(home:, cwd:)
    Riggs::CLI::Setup.new(home: home, cwd: cwd).call
  end

  def test_running_setup_twice_leaves_an_existing_global_config_byte_for_byte
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [home, repo].each { |d| FileUtils.mkdir_p(d) }
      run_setup(home: home, cwd: repo)
      global = File.join(home, ".riggs", "config.yml")
      before = File.read(global)
      FileUtils.rm_rf(File.join(home, ".riggs", "skills"))
      run_setup(home: home, cwd: repo)
      assert_equal before, File.read(global)
      assert File.directory?(File.join(home, ".riggs", "skills")), "deleted skills dir must be repaired"
    end
  end

  def test_the_first_global_creation_seeds_from_an_existing_agent_hubrc
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [home, repo].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(repo, ".agent_hubrc"), Psych.dump(
                                                    "users" => { "matt" => { "role" => "pm" } },
                                                    "roles" => { "pm" => %w[publish] },
                                                    "providers" => { "mock" => { "type" => "mock" } }
                                                  ))
      run_setup(home: home, cwd: repo)
      global = Psych.safe_load(File.read(File.join(home, ".riggs", "config.yml")), aliases: true)
      assert_equal({ "role" => "pm" }, global["users"]["matt"])
      assert_equal %w[publish], global["roles"]["pm"]
    end
  end

  def test_seeding_drops_credentials_rather_than_persisting_them_globally
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [home, repo].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(repo, ".agent_hubrc"), Psych.dump(
                                                    "providers" => {
                                                      "openai" => { "type" => "openai", "model" => "gpt-5",
                                                                    "api_key" => "sk-live-SENTINEL-4c1a" }
                                                    }
                                                  ))
      out, = capture_io { run_setup(home: home, cwd: repo) }
      global_raw = File.read(File.join(home, ".riggs", "config.yml"))
      refute_includes global_raw, "sk-live-SENTINEL-4c1a"
      refute_includes global_raw, "api_key"
      assert_includes global_raw, "gpt-5", "non-credential provider fields must survive"
      assert_includes out, "api_key", "a dropped key must be named so the operator can move it to the env"
    end
  end

  def test_the_global_config_is_written_private_to_the_owner
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [home, repo].each { |d| FileUtils.mkdir_p(d) }
      run_setup(home: home, cwd: repo)
      assert_equal 0o600, File.stat(File.join(home, ".riggs", "config.yml")).mode & 0o777
    end
  end

  def test_the_generated_project_skeleton_names_only_permitted_keys_and_is_commented
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [home, repo].each { |d| FileUtils.mkdir_p(d) }
      run_setup(home: home, cwd: repo)
      raw = File.read(File.join(repo, ".riggs", "config.yml"))
      refute_match(/^\s*sqlite_(path|memory)/, raw)
      raw.each_line do |line|
        next if line.strip.empty? || line.strip.start_with?("#")

        flunk "skeleton must be fully commented; found live line: #{line.inspect}"
      end
    end
  end

  def test_seeding_never_runs_against_an_existing_global_config
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      first = File.join(dir, "first")
      second = File.join(dir, "second")
      [home, first, second].each { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(first, ".agent_hubrc"), Psych.dump("users" => { "a" => { "role" => "pm" } }))
      run_setup(home: home, cwd: first)
      File.write(File.join(second, ".agent_hubrc"), Psych.dump("users" => { "b" => { "role" => "pm" } }))
      run_setup(home: home, cwd: second)
      global = Psych.safe_load(File.read(File.join(home, ".riggs", "config.yml")), aliases: true)
      assert global["users"].key?("a")
      refute global["users"].key?("b")
    end
  end

  def test_home_as_the_project_writes_no_project_tier_over_the_global_one
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      FileUtils.mkdir_p(home)
      run_setup(home: home, cwd: home)
      global = File.join(home, ".riggs", "config.yml")
      assert File.exist?(global)
      cfg = Psych.safe_load(File.read(global), aliases: true)
      refute_nil cfg["users"], "the global config must not have been clobbered by a project skeleton"
    end
  end

  def test_setup_records_trust_for_the_project_path
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [home, repo].each { |d| FileUtils.mkdir_p(d) }
      run_setup(home: home, cwd: repo)
      trust = Riggs::Trust.new(path: File.join(home, ".riggs", "trust.yml"))
      assert trust.trusted?(File.realpath(repo))
    end
  end

  def test_setup_writes_a_project_skeleton_that_does_not_trip_a_hard_error
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [home, repo].each { |d| FileUtils.mkdir_p(d) }
      run_setup(home: home, cwd: repo)
      trust = Riggs::Trust.new(path: File.join(home, ".riggs", "trust.yml"))
      cfg = Riggs::Identity.resolved(
        cwd: repo, trust: trust, global_config: File.join(home, ".riggs", "config.yml")
      )
      refute_nil cfg.config[:default_user]
    end
  end
end
```

- [ ] **Step 2: Run to verify failure** — `NameError: uninitialized constant Riggs::CLI::Setup`

- [ ] **Step 3: Implement**

Extract the setup body out of the Thor command into `lib/riggs/cli/setup.rb` as `Riggs::CLI::Setup`, taking `home:` and `cwd:` so it is testable without changing the developer's home directory. The Thor `setup` command becomes a two-line call into it.

**Add `require_relative "setup"` to `lib/riggs/cli/commands.rb`.** Without it
`Riggs::CLI::Setup` is undefined in both the Thor command and the test, and
nothing else in the plan pulls the file in.

`Setup#call` performs, in order:

1. Compute `project_path = Config::Resolver.project_path(cwd)`.
2. Ensure `<home>/.riggs/`, `skills/`, `workflows/` — `mkdir_p` each, which is already idempotent.
3. Ensure `<home>/.riggs/trust.yml` via `Trust#grant!` later; no separate creation step.
4. If `<home>/.riggs/config.yml` does **not** exist: build the default hub config (reuse the existing literal from `commands.rb:57-108`, keeping `sqlite_memory` — it is a global-only key and belongs here — and pointing `sqlite_path` at `<home>/.riggs/riggs.sqlite3` rather than into the repo), then **seed** from `project_path`'s `.riggs/config.yml` or `.agent_hubrc` if one exists, taking `users` and `roles` wholesale and each provider's name plus only `Config::Merge::PROVIDER_FIELDS` (`model`, `base_url`, `pricing`, `relay_chain`, `auth`) and `type`. **Every other provider key is dropped and printed by name.** A legacy `.agent_hubrc` may well carry an `api_key`, and copying `providers` wholesale would persist it in `~/.riggs/config.yml` — breaking "no tier holds credentials" through the very step meant to adopt the new layout. Write it **and `File.chmod(0o600, path)`** — R11.1 requires it of every writer, not only the trust registry. Print what was seeded, or print plainly that an empty global config was created.
5. If it does exist: print `⏭️  Keeping existing <path>`.
6. Ensure the database at the global `sqlite_path` via `Storage.new(db_path:).close`.
7. Unless `project_path == File.expand_path(home)`: `mkdir_p` the project `config/riggs/{workflows,skills}`, copy the example playbook and skill as today, and write `<project_path>/.riggs/config.yml` if absent — a commented skeleton whose keys are exactly `Config::Merge::PROJECT_KEYS` (`default_user`, `roles`, `users`, `providers`, `mcp_servers`), **all commented out**. It MUST NOT contain `sqlite_path` or `sqlite_memory` in any form. Commenting every key is what makes it both a useful template and unable to trip a hard error; the spec's earlier "no users or roles" wording is superseded by R11.8's allowlist.
8. `Trust.new(path: <home>/.riggs/trust.yml).grant!(project_path)` and print that trust was recorded.

Every print stays in the existing emoji style.

- [ ] **Step 4: Verify pass, then full suite.** Existing `test_cli.rb` setup tests will need their expectations updated for the new output and paths; update them rather than weakening the new behavior.

- [ ] **Step 5: Commit**

```bash
git add lib/riggs/cli/setup.rb lib/riggs/cli/commands.rb test/test_setup_tiers.rb test/test_cli.rb
git commit -m "Make riggs setup ensure both tiers per artifact, seeding on first creation"
```

---

### Task 8: Trust commands and identity provenance

**Files:**
- Modify: `lib/riggs/cli/commands.rb`
- Test: `test/test_trust_cli.rb`

**Interfaces:**
- Consumes: `Trust`, `Identity.resolved`.
- Produces: `riggs trust`, `riggs trust:list`, `riggs trust:forget PATH`, `riggs mcp:approve NAME`, and a provenance line on every run.

- [ ] **Step 1: Write failing tests** asserting:
  - `riggs trust` grants the current project path and prints it.
  - `riggs trust:list` prints granted paths and marks any whose directory no longer exists.
  - `riggs trust:forget PATH` removes an entry and reports when there was nothing to remove.
  - `riggs mcp:approve NAME` records the digest of the currently-configured command and refuses, with a message naming the tier, when the named server is global (there is nothing to approve). It also refuses when the path is not trusted, pointing at `riggs trust` — approval presumes the first gate already passed, and the declaration being approved lives in a file that may not be read yet.
  - `workflow:run` prints `▸ running as <id> (<role>) — from <path>` where `<path>` is the file the identity came from, taken from `provenance[:users][id]` and `provenance[:default_user]`.

- [ ] **Step 2–4: Red, implement, green.**

Register each command with `desc` and Thor `map` in the existing style (`map "trust:list" => :trust_list`). `riggs trust` is a bare command like `setup` and `serve`; also register `map "trust:grant" => :trust` for symmetry. Do **not** add `riggs projects` — it is Phase 11b.

The provenance line goes in the private helper that every command already uses to resolve identity, not in each command, so no command can be added later that skips it.

- [ ] **Step 5: Commit**

```bash
git add lib/riggs/cli/commands.rb test/test_trust_cli.rb
git commit -m "Add trust CLI commands and print identity provenance on every run"
```

---

### Task 9: Tier-aware `ConfigStore` and web config view

**Files:**
- Modify: `lib/riggs/config_store.rb`
- Modify: `lib/riggs/web/app.rb:96-98`, `lib/riggs/web/views/config.erb`
- Test: `test/test_config_store.rb` (extend)

**Interfaces:**
- Consumes: `Identity.resolved`, `Identity.config_path`.
- Produces: `ConfigStore.new(path:, tier:)` where `tier` is `:project` or `:global`; `#public_view` gains a `_tier` and `_path` key; writes still refuse when the file is missing.

- [ ] **Step 1: Write failing tests** asserting:
  - `ConfigStore` defaults to the trusted project tier path when one exists and the global path otherwise.
  - **`ConfigStore.new(path:)` pointed at an untrusted project file raises rather than reading it.** `ConfigStore#read` calls `Identity.load_config(@path)`, which is a raw single-file reader that never consults trust, and `web/app.rb:96-98` hands it `Identity.config_path`. Task 4 makes `config_path` return nil for an untrusted project, but a caller can still pass the path explicitly — so the refusal belongs in `ConfigStore` too. Assert with a `.riggs/config.yml` in an untrusted temp project.
  - `public_view` reports which tier and path it read, so the web UI can label it.
  - `merge!` writing `sqlite_path`, `sqlite_memory`, or a provider `api_key` into the project tier raises `Riggs::Error` **before touching the file** — asserted by capturing the file's bytes before and after and confirming they are identical, and that no `.bak.*` sibling was created.

That last one matters: `ConfigStore#merge!` is reachable from `/config` over HTTP, so it is the one path where a *remote* write could try to set a key the merge algebra forbids. Validating in `Config::Merge` alone is not enough, because `write!` calls `backup!` and writes before anything merges.

- [ ] **Step 2–4: Red, implement, green.**

`ConfigStore#write!` validates the candidate document by running `Config::Merge.call` against the current global tier and raising before `backup!` if it would not merge. Show the tier and path in `config.erb`.

- [ ] **Step 5: Commit**

```bash
git add lib/riggs/config_store.rb lib/riggs/web/app.rb lib/riggs/web/views/config.erb test/test_config_store.rb
git commit -m "Make ConfigStore tier-aware and validate writes against the merge algebra"
```

---

## Definition of done for 11a

- All nine tasks committed, `bundle exec rubocop` clean, `bundle exec rake test` 0 failures.
- The mutation verifications in Tasks 1, 2, 3 and 6 have each been run and their failure output pasted into the task report. A security claim nobody broke is a claim nobody tested.
- The hostile-clone demonstration covers **all four** channels from the spec's
  Phase 11a definition of done, run by hand and reported with actual output:
  MCP command (no marker file), privileged user (`default_user` ignored,
  provenance line printed), workflow `base_url` exfiltration (a local
  `TCPServer` records no connection), and `sqlite_memory.vector_path` (rejected
  before any load). Earlier drafts closed the first two while claiming all.
- The exfiltration check is its own automated test, not only a manual step:

```ruby
  def test_an_untrusted_workflow_cannot_redirect_a_provider_base_url
    server = TCPServer.new("127.0.0.1", 0)
    hits = []
    Thread.new { loop { hits << server.accept } }
    # workflow in an untrusted repo sets providers.openai.base_url to this port
    # ... run the workflow ...
    assert_empty hits, "an untrusted workflow must not reach an attacker-chosen host"
  ensure
    server&.close
  end
```

  Asserted on a real socket because the whole point is what crossed the
  process boundary; arguments handed to a stubbed HTTP client prove nothing.
- `grep -rn "Manager.from_config" lib` shows `provenance:` on every hit,
  `grep -rn "config/riggs/workflows" lib` shows hits only inside
  `Triggers.default_roots`, and `MCP::Client.from_config` no longer exists.

## Explicitly out of scope

R11.6 (`project_path` column, `riggs cost`, `riggs projects`) and R11.7 (memory scoping) are Phase 11b. Do not add the column, the commands, or the namespace composition in this phase. If a task seems to need them, it has drifted.

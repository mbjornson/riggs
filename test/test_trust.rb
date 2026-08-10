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

  def digest_for(command, args, env)
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
    base = digest_for("npx", %w[-y hb-mcp], {})
    refute_equal base, digest_for("node", %w[-y hb-mcp], {})
    refute_equal base, digest_for("npx", %w[-y evil-mcp], {})
    refute_equal base, digest_for("npx", %w[-y hb-mcp --extra], {})
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
      d = digest_for("npx", %w[hb], {})
      trust.approve_mcp!("/p", "honeybadger", d)
      assert trust.mcp_approved?("/p", "honeybadger", d)
      refute trust.mcp_approved?("/other", "honeybadger", d)
      refute trust.mcp_approved?("/p", "context7", d)
    end
  end

  def test_a_changed_command_is_no_longer_approved
    with_trust do |trust, _|
      trust.grant!("/p")
      trust.approve_mcp!("/p", "hb", digest_for("npx", %w[hb], {}))
      refute trust.mcp_approved?("/p", "hb", digest_for("npx", %w[hb --now-with-extras], {}))
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
        trust.approve_mcp!("/p", "hb", digest_for("npx", [], {}))
      end
      assert_includes err.message, "not trusted"
      refute trust.trusted?("/p")
    end
  end

  def test_recording_an_approval_never_creates_trust
    with_trust do |trust, _|
      trust.grant!("/p")
      trust.approve_mcp!("/p", "hb", digest_for("npx", [], {}))
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
      first = digest_for(link, [], {})
      File.unlink(link)
      File.symlink(File.join(dir, "b"), link)
      refute_equal first, digest_for(link, [], {})
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

  # --- a corrupt registry must not take every command down with it ---
  #
  # trust.yml is the one file riggs writes itself, so it is the one most
  # likely to be found half-written after a crash or a full disk. Before this
  # guard, `data["projects"] ||= {}` raised IndexError on a String document
  # and TypeError on a list, from inside `trusted?` -- which every riggs
  # command calls. The failure was an opaque stack trace with no way out.

  def corrupt(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "trust.yml")
      File.write(path, body)
      yield Riggs::Trust.new(path: path)
    end
  end

  def test_a_trust_file_that_is_not_a_mapping_is_ignored_rather_than_raising
    corrupt("just a string\n") { |trust| assert_reads_as_empty(trust) }
  end

  def test_a_trust_file_that_is_a_list_is_ignored_rather_than_raising
    corrupt("- a\n- b\n") { |trust| assert_reads_as_empty(trust) }
  end

  def test_a_trust_file_whose_projects_key_is_not_a_mapping_is_ignored
    corrupt("projects: nope\n") { |trust| assert_reads_as_empty(trust) }
  end

  def test_a_trust_file_whose_project_entry_is_not_a_mapping_is_ignored
    corrupt("projects:\n  \"/p\": oops\n") { |trust| assert_reads_as_empty(trust) }
  end

  # Ignoring a corrupt file must not be silent: the operator is about to be
  # re-prompted for trust they already granted, and needs to know why.
  def test_ignoring_a_corrupt_trust_file_warns_naming_the_file
    corrupt("just a string\n") do |trust|
      _out, err = capture_io { trust.trusted?("/p") }
      assert_includes err, trust.path
    end
  end

  # Recovery: a corrupt file must be writable over, not permanently wedged.
  def test_a_corrupt_trust_file_can_be_granted_over
    corrupt("projects: nope\n") do |trust|
      capture_io { trust.grant!("/p") }
      assert trust.trusted?("/p")
    end
  end

  # --- a malformed declaration reaches the digest as data, not as a crash ---

  def test_a_non_mapping_env_does_not_crash_the_digest
    assert_match(/\Asha256:/, Riggs::Trust.digest(command: "npx", args: [], env: "oops"))
  end

  def test_an_env_that_is_not_a_mapping_digests_as_no_forwarded_variables
    assert_equal Riggs::Trust.digest(command: "npx", args: [], env: {}),
                 Riggs::Trust.digest(command: "npx", args: [], env: "oops")
  end

  # File.expand_path raises ArgumentError on a NUL byte, which escaped as a
  # raw crash from inside digest computation. No filename may contain one, so
  # such a command is unresolvable by definition.
  def test_a_command_containing_a_nul_byte_does_not_crash_the_digest
    assert_match(/\Asha256:/, Riggs::Trust.digest(command: "a\u0000b", args: [], env: {}))
  end

  def test_a_command_containing_a_nul_byte_never_resolves_to_a_real_file
    resolved = Riggs::Trust.resolve_executable(command: "/bin/sh\u0000", env: {})
    refute_equal "/bin/sh", resolved
    assert_match(/\Aunresolved:/, resolved)
  end

  def test_an_empty_command_does_not_resolve_to_a_directory
    assert_equal "unresolved:", Riggs::Trust.resolve_executable(command: "", env: { "PATH" => "/usr/bin" })
  end

  # --- the registry must not become a write primitive aimed elsewhere ---
  #
  # Verified before the guard existed: riggs wrote its projects list THROUGH
  # the link into the target, and chmod'd that target to 0600.
  def test_writing_refuses_to_follow_a_symbolic_link
    Dir.mktmpdir do |dir|
      victim = File.join(dir, "victim.yml")
      File.write(victim, "some_key: some_value\n")
      File.chmod(0o644, victim)
      File.symlink(victim, File.join(dir, "trust.yml"))
      err = assert_raises(Riggs::Error) { Riggs::Trust.new(path: File.join(dir, "trust.yml")).grant!("/pwned") }
      assert_includes err.message, "symbolic link"
      assert_equal "some_key: some_value\n", File.read(victim)
      assert_equal 0o644, File.stat(victim).mode & 0o777
    end
  end

  private

  def assert_reads_as_empty(trust)
    capture_io do
      refute trust.trusted?("/p")
      assert_empty trust.projects
      assert_nil trust.trusted_at("/p")
    end
  end

  def write_fake(dir, name)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end
end

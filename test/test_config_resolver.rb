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

  # This compatibility seam keeps the resolver gate test executable before
  # Task 6 adds the provenance keyword to the MCP manager's public factory.
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

  def test_an_untrusted_project_file_declaring_an_mcp_server_never_spawns_it
    in_sandbox do |root, trust, global|
      marker = File.join(root, "pwned-9f2a")
      write_project(root, "mcp_servers" => {
                      "evil" => { "command" => "/bin/sh", "args" => ["-c", "touch #{marker}"] }
                    })
      result = resolve(root, trust, global)
      refute result.trusted

      # Called against the CURRENT Manager signature on purpose. Task 6 adds a
      # required `provenance:` keyword, and when it does this line must become
      #
      #   Manager.from_config(servers, provenance: servers.keys.to_h { |k| [k, :global] })
      #
      # -- every server declared :global, so Task 6's approval gate is stripped
      # away and the only thing standing between the config and the marker file
      # is the trust check under test. A gate that blocks the spawn for the
      # wrong reason would prove Task 6 twice and Task 2 not at all.
      #
      # Deliberately NOT written as a runtime check on the method's parameters:
      # that silently keeps passing when Task 6 renames the keyword, and passes
      # for whichever reason happens to hold. Hard-coding the call means Task 6
      # breaks this test loudly and has to come back and read the paragraph
      # above.
      servers = result.project[:mcp_servers] || {}
      Riggs::MCP::Manager.from_config(servers).list_tools
      refute File.exist?(marker), "an untrusted project's MCP command must never run"
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "fileutils"

class TestTrustCLI < Minitest::Test
  def test_trust_grants_the_current_project_path_and_prints_it
    with_tmp_project do |repo|
      project_path = Riggs::Config::Resolver.project_path(repo)
      Riggs::Trust.default.forget!(project_path)

      out, = run_cli(%w[trust])

      assert Riggs::Trust.default.trusted?(project_path)
      assert_includes out, project_path
    end
  end

  def test_trust_list_marks_paths_whose_directories_are_missing
    with_tmp_project do |repo|
      trust = Riggs::Trust.default
      missing = File.join(repo, "missing-project")
      FileUtils.mkdir_p(missing)
      trust.grant!(missing)
      FileUtils.rm_rf(missing)

      out, = run_cli(["trust:list"])

      assert_includes out, Riggs::Config::Resolver.project_path(repo)
      assert_match(/#{Regexp.escape(missing)}.*missing/i, out)
    end
  end

  def test_trust_forget_removes_an_entry_and_reports_when_nothing_was_removed
    with_tmp_project do |repo|
      trust = Riggs::Trust.default
      path = File.join(repo, "forgettable")
      trust.grant!(path)

      out, = run_cli(["trust:forget", path])
      assert_includes out, path
      refute trust.trusted?(path)

      out2, = run_cli(["trust:forget", path])
      assert_match(/nothing to remove/i, out2)
    end
  end

  # `riggs trust` grants the path Config::Resolver resolves, which is a
  # realpath. `trust:forget` compared its raw argument, so every equivalent
  # spelling of the same directory reported "Nothing to remove" and left the
  # grant in place -- a revocation command telling the operator there was
  # nothing to revoke while the repository stayed trusted.
  def test_trust_forget_revokes_however_the_operator_spells_the_path
    with_tmp_project do |repo|
      trust = Riggs::Trust.default
      granted = Riggs::Config::Resolver.project_path(repo)
      link = File.join(File.dirname(repo), "repo-link-#{File.basename(repo)}")
      File.symlink(repo, link)
      FileUtils.mkdir_p(File.join(repo, "child"))

      { "trailing slash" => "#{repo}/", "dot-dot" => File.join(repo, "child", ".."),
        "symlink" => link }.each do |label, spelling|
        trust.grant!(granted)
        out, = run_cli(["trust:forget", spelling])

        refute trust.trusted?(granted), "#{label} must revoke the grant"
        assert_match(/forgot/i, out, "#{label} must report a removal, not a no-op")
      end
    end
  end

  # A stale entry is the main thing trust:list exists to surface, so
  # canonicalizing must not make one unforgettable: realpath cannot resolve a
  # directory that is gone.
  def test_trust_forget_still_removes_an_entry_whose_directory_no_longer_exists
    with_tmp_project do |repo|
      trust = Riggs::Trust.default
      missing = File.join(repo, "gone")
      trust.grant!(missing)

      out, = run_cli(["trust:forget", missing])

      refute trust.trusted?(missing)
      assert_match(/forgot/i, out)
    end
  end

  def test_mcp_approve_refuses_global_servers_naming_the_tier
    with_tmp_project do
      write_global_mcp("global_one" => { "command" => "echo", "args" => ["global"] })

      _out, err = capture_io do
        assert_raises(SystemExit) { Riggs::CLI.start(["mcp:approve", "global_one"]) }
      end

      assert_match(/global/i, err)
      assert_match(/nothing to approve/i, err)
    end
  end

  def test_mcp_approve_surfaces_the_untrusted_path_error_from_trust
    with_tmp_project do |repo|
      project_path = Riggs::Config::Resolver.project_path(repo)
      Riggs::Trust.default.forget!(project_path)
      write_project_mcp("project_one" => { "command" => "echo", "args" => ["project"] })

      _out, err = capture_io do
        assert_raises(SystemExit) { Riggs::CLI.start(["mcp:approve", "project_one"]) }
      end

      assert_match(/not trusted/i, err)
      assert_match(/riggs trust/i, err)
    end
  end

  def test_cli_approval_is_admitted_by_the_manager_gate
    with_tmp_project do |repo|
      write_project_mcp("project_one" => { "command" => "echo", "args" => ["project"] })

      unresolved = manager_for(repo)
      assert_raises(Riggs::MCP::NotApproved) { unresolved.send(:client_for, "project_one") }

      run_cli(["mcp:approve", "project_one"])

      approved = manager_for(repo)
      refute_nil approved.send(:client_for, "project_one")
    end
  end

  def test_workflow_run_prints_provenance_from_the_user_tier_when_it_disagrees_with_default_user
    with_tmp_project do
      write_project_override(
        "roles" => { "eng_runner" => %w[run_workflow approve_gates read_workflow inspect_run manage_mcp] },
        "users" => { "eng_bob" => { "role" => "eng_runner" } }
      )

      out, = run_cli(["workflow:run", "example_triage", "--auto-approve", "--ticket", "hello"])

      assert_includes out, "▸ running as eng_bob (eng_runner) — from #{File.expand_path('.riggs/config.yml')}"
    end
  end

  def test_workflow_run_keeps_global_provenance_when_default_user_tier_disagrees
    with_tmp_project do
      write_global_default("pm_alice")
      write_project_override("default_user" => "eng_bob")

      out, = run_cli(["workflow:run", "example_triage", "--auto-approve", "--ticket", "hello"])

      assert_includes out, "▸ running as eng_bob (engineer) — from #{Riggs::Config::Resolver.global_config}"
    end
  end

  private

  def run_cli(args)
    capture_io { Riggs::CLI.start(args) }
  rescue SystemExit => e
    flunk "CLI exited unexpectedly for #{args.join(' ')} (status=#{e.status})"
  end

  def manager_for(repo)
    trust = Riggs::Trust.default
    resolved = Riggs::Identity.resolved(cwd: repo, trust: trust)
    Riggs::MCP::Manager.from_config(
      resolved.config[:mcp_servers],
      provenance: resolved.provenance[:mcp_servers],
      trust: trust,
      project_path: resolved.project_path
    )
  end

  def write_global_default(user)
    path = Riggs::Config::Resolver.global_config
    config = Psych.safe_load(File.read(path), aliases: true) || {}
    config["default_user"] = user
    File.write(path, Psych.dump(config))
  end

  def write_global_mcp(servers)
    path = Riggs::Config::Resolver.global_config
    config = Psych.safe_load(File.read(path), aliases: true) || {}
    config["mcp_servers"] = servers
    File.write(path, Psych.dump(config))
  end

  def write_project_mcp(servers)
    write_project_override("mcp_servers" => servers)
  end

  def write_project_override(values)
    FileUtils.mkdir_p(".riggs")
    File.write(".riggs/config.yml", Psych.dump(values))
  end
end

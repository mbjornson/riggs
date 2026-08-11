# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"

class TestMcpApproval < Minitest::Test
  SERVERS = {
    global_one: { command: "echo", args: %w[global] },
    project_one: { command: "echo", args: %w[project] }
  }.freeze
  PROVENANCE = { global_one: :global, project_one: :project }.freeze

  def test_an_unapproved_project_server_raises_rather_than_spawning
    with_trust do |trust|
      error = assert_raises(Riggs::MCP::NotApproved) { manager(trust).send(:client_for, "project_one") }
      assert_includes error.message, "project_one"
      assert_includes error.message, "riggs mcp:approve project_one"
    end
  end

  def test_a_globally_defined_server_needs_no_approval
    with_trust { |trust| refute_nil manager(trust).send(:client_for, "global_one") }
  end

  def test_an_approved_project_server_spawns
    with_trust do |trust|
      approve(trust, "project_one", "echo", %w[project])
      refute_nil manager(trust).send(:client_for, "project_one")
    end
  end

  # The client must be built with the RESOLVED path, or popen2 re-consults
  # PATH at spawn time and can exec a different binary under this approval.
  def test_an_approved_client_is_constructed_with_the_resolved_executable
    with_trust do |trust|
      approve(trust, "project_one", "echo", %w[project])
      command = manager(trust).send(:client_for, "project_one").instance_variable_get(:@command)
      assert command.start_with?("/"), "expected an absolute resolved path, got #{command.inspect}"
      assert_equal Riggs::Trust.resolve_executable(command: "echo", env: {}), command
    end
  end

  # The one test in this file that actually reaches Open3. Every other
  # assertion stops at Client construction, which cannot distinguish "the gate
  # allowed it" from "the gate allowed it and the spawn would have failed".
  def test_an_unapproved_server_never_reaches_open3
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "spawned-4c1a")
      trust = trusted(dir)
      cfg = { evil: { command: "/bin/sh", args: ["-c", "touch #{marker}"] } }
      manager = configured_manager(cfg, { evil: :project }, trust)
      assert_raises(Riggs::MCP::NotApproved) { manager.list_tools }
      refute File.exist?(marker), "an unapproved server must never be spawned"
    end
  end

  def test_an_approved_server_does_reach_open3
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "spawned-9f2a")
      trust = trusted(dir)
      cfg = { ok: { command: "/bin/sh", args: ["-c", "touch #{marker}; exec cat"] } }
      approve(trust, "ok", "/bin/sh", cfg[:ok][:args])
      client = configured_manager(cfg, { ok: :project }, trust).send(:client_for, "ok")
      client.start!
      assert File.exist?(marker), "an approved server must actually spawn; otherwise the gate proves nothing"
    ensure
      client&.close
    end
  end

  # End to end: approve under one PATH, then make the same name resolve to a
  # different binary. The stale approval must not carry over.
  def test_an_approval_does_not_survive_the_name_resolving_elsewhere
    Dir.mktmpdir do |dir|
      build_swappable_binaries(dir)
      trust = trusted(dir)
      approve(trust, "swap", "swapmcp", [], "PATH" => File.join(dir, "a"))
      refute_nil swap_manager(dir, trust, "a").send(:client_for, "swap")
      assert_raises(Riggs::MCP::NotApproved) { swap_manager(dir, trust, "b").send(:client_for, "swap") }
    end
  end

  def test_a_changed_command_revokes_the_approval
    with_trust do |trust|
      approve(trust, "project_one", "echo", %w[old])
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
      $stdin = StdinProbe.new
      assert_raises(Riggs::MCP::NotApproved) { manager(trust).send(:client_for, "project_one") }
    ensure
      $stdin = original
    end
  end

  def test_an_interactive_context_that_is_declined_still_raises
    with_trust do |trust|
      original = $stdin
      $stdin = StringIO.new("n\n")
      assert_raises(Riggs::MCP::NotApproved) { interactive_manager(trust).send(:client_for, "project_one") }
      refute trust.mcp_approved?("/repo", "project_one", digest("echo", %w[project]))
    ensure
      $stdin = original
    end
  end

  def test_an_interactive_context_that_is_accepted_records_the_approval
    with_trust do |trust|
      original = $stdin
      $stdin = StringIO.new("y\n")
      refute_nil interactive_manager(trust).send(:client_for, "project_one")
      assert trust.mcp_approved?("/repo", "project_one", digest("echo", %w[project]))
    ensure
      $stdin = original
    end
  end

  # Fail closed: a Manager that cannot say where a server came from must refuse.
  def test_a_manager_built_without_provenance_refuses_to_spawn
    with_trust do |trust|
      manager = configured_manager(SERVERS, {}, trust)
      assert_raises(Riggs::MCP::NotApproved) { manager.send(:client_for, "project_one") }
    end
  end

  def test_from_config_requires_provenance
    assert_raises(ArgumentError) { Riggs::MCP::Manager.from_config(SERVERS) }
  end

  # Every other test here builds a flat PROVENANCE by hand, which agrees with the
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
      manager = Riggs::MCP::Manager.from_config(
        resolved.config[:mcp_servers], provenance: resolved.provenance[:mcp_servers], trust: trust, project_path: dir
      )
      refute_nil manager.send(:client_for, "ctx")
    end
  end

  # The gate raising is worthless if the caller eats it.
  def test_not_approved_escapes_list_tools_rather_than_becoming_an_empty_list
    with_trust { |trust| assert_raises(Riggs::MCP::NotApproved) { manager(trust).list_tools } }
  end

  def test_not_approved_escapes_ping_rather_than_becoming_a_failed_result
    with_trust { |trust| assert_raises(Riggs::MCP::NotApproved) { manager(trust).ping("project_one") } }
  end

  # R11.9 7b. A regression tripwire, NOT a proof: it matches a string pattern,
  # so it will miss `Client.send(:new, ...)`, `Client.new(**cfg)`, an aliased
  # constant, or a factory, and it will fire on a legitimate in-process
  # construction. Its job is to make a future `MCP::Client.new` in lib/ fail
  # loudly enough that someone thinks about provenance. The real audit is the
  # spec's route list, done by reading.
  def test_no_config_driven_client_construction_exists_outside_the_manager
    refute Riggs::MCP::Client.respond_to?(:from_config), "Client.from_config must not exist"
    offenders = Dir.glob(File.expand_path("../lib/**/*.rb", __dir__)).select do |file|
      !file.end_with?("mcp/manager.rb") && File.read(file).match?(/MCP::Client\.new|Client\.new\(command:/)
    end
    assert_empty offenders, "only Manager#client_for may construct an MCP::Client from configuration"
  end

  def test_the_display_string_redacts_secret_bearing_flags
    shown = Riggs::MCP::Approval.redact("npx", ["-y", "hb-mcp", "--token", "sk-live-abc123", "--api-key=sk-xyz"])
    refute_includes shown, "sk-live-abc123"
    refute_includes shown, "sk-xyz"
    assert_includes shown, "--token"
    assert_includes shown, "[redacted]"
  end

  def test_redaction_leaves_ordinary_arguments_alone
    assert_includes Riggs::MCP::Approval.redact("npx", %w[-y hb-mcp --port 8080]), "8080"
  end

  # The approval's environment claim must be true at the OS boundary. This
  # checks the spawned process rather than the hash Riggs handed Open3.
  def test_an_approved_server_cannot_read_an_undeclared_parent_environment_variable
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "child-environment")
      previous = ENV.fetch("RIGGS_MCP_SENTINEL", nil)
      ENV["RIGGS_MCP_SENTINEL"] = "parent-only"
      trust = trusted(dir)
      cfg = { scoped: { command: "/bin/sh", args: ["-c", "printf '%s' \"${RIGGS_MCP_SENTINEL-unset}\" > #{marker}; exec cat"] } }
      approve(trust, "scoped", "/bin/sh", cfg[:scoped][:args])
      client = configured_manager(cfg, { scoped: :project }, trust).send(:client_for, "scoped")
      client.start!
      assert_equal "unset", File.read(marker)
    ensure
      client&.close
      ENV["RIGGS_MCP_SENTINEL"] = previous
      ENV.delete("RIGGS_MCP_SENTINEL") if previous.nil?
    end
  end

  private

  def manager(trust)
    Riggs::MCP::Manager.from_config(
      SERVERS, provenance: PROVENANCE, trust: trust, project_path: "/repo", interactive: false
    )
  end

  def approve(trust, name, command, args, env = {})
    trust.approve_mcp!("/repo", name, digest(command, args, env))
  end

  def digest(command, args, env = {})
    resolved = Riggs::Trust.resolve_executable(command: command, env: env)
    Riggs::Trust.digest(command: resolved, args: args, env: env)
  end

  def trusted(dir)
    trust = Riggs::Trust.new(path: File.join(dir, "trust.yml"))
    trust.grant!("/repo")
    trust
  end

  def configured_manager(config, provenance, trust)
    Riggs::MCP::Manager.from_config(config, provenance: provenance, trust: trust, project_path: "/repo", interactive: false)
  end

  def interactive_manager(trust)
    Riggs::MCP::Manager.from_config(
      SERVERS, provenance: PROVENANCE, trust: trust, project_path: "/repo", interactive: true
    )
  end

  def build_swappable_binaries(dir)
    %w[a b].each do |subdirectory|
      bin = File.join(dir, subdirectory, "swapmcp")
      FileUtils.mkdir_p(File.dirname(bin))
      File.write(bin, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, bin)
    end
  end

  def swap_manager(dir, trust, subdirectory)
    env = { "PATH" => File.join(dir, subdirectory) }
    cfg = { swap: { command: "swapmcp", args: [], env: env } }
    configured_manager(cfg, { swap: :project }, trust)
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

  class StdinProbe
    def gets
      raise "stdin was read in a non-interactive context"
    end

    def tty?
      false
    end
  end
end

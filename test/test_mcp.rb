# frozen_string_literal: true

require "test_helper"
require "json"
require "rbconfig"

class TestMCPClient < Minitest::Test
  def test_manager_from_empty
    mgr = Riggs::MCP::Manager.from_config({}, provenance: {})
    assert_empty mgr.server_names
    assert_empty mgr.list_tools
  end

  def test_start_rejects_blank_command
    client = Riggs::MCP::Client.new(command: "   ", args: [])
    err = assert_raises(Riggs::MCP::Client::Error) { client.start! }
    assert_match(/blank/i, err.message)
  end

  # Open3 treats a single string as a shell command when it contains
  # metacharacters. The client must resolve a binary and spawn argv so this
  # never creates the redirected file.
  def test_start_does_not_run_shell_metacharacter_command
    Dir.mktmpdir do |dir|
      pwned = File.join(dir, "pwned")
      cmd = "echo pwned > #{pwned} && echo done"
      client = Riggs::MCP::Client.new(command: cmd, args: [])

      err = assert_raises(Riggs::MCP::Client::Error) { client.start! }

      refute_path_exists pwned, "shell must not interpret command; #{pwned} was created"
      assert_match(/not found|blank/i, err.message)
    end
  end

  def test_start_with_true_fails_cleanly_without_shell
    client = Riggs::MCP::Client.new(command: "true", args: [])
    err = assert_raises(Riggs::MCP::Client::Error) { client.start! }
    assert_match(/closed unexpectedly/i, err.message)
  end

  def test_start_with_script_path_and_args_speaks_mcp
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.rb")
      File.write(path, <<~'RUBY')
        require "json"
        STDOUT.sync = true
        STDIN.each_line do |line|
          msg = JSON.parse(line.strip)
          next unless msg["method"] == "initialize"

          STDOUT.write(JSON.generate(jsonrpc: "2.0", id: msg["id"], result: {}) + "\n")
        end
      RUBY
      client = Riggs::MCP::Client.new(command: RbConfig.ruby, args: [path])
      client.start!
      client.close
    end
  end
end

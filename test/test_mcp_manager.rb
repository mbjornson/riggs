# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "rbconfig"

class TestMCPManager < Minitest::Test
  # Speaks the MCP stdio transport per spec (2024-11-05): newline-delimited JSON-RPC.
  def write_fake_server(path, tool_name)
    template = <<~'SERVER_SCRIPT'
      require "json"
      TOOL = "__TOOL__"
      STDOUT.sync = true
      def write_msg(obj)
        STDOUT.write(JSON.generate(obj) + "\n")
      end
      initialized = false
      STDIN.each_line do |line|
        line = line.strip
        next if line.empty?
        msg = JSON.parse(line)
        case msg["method"]
        when "initialize"
          initialized = true
          write_msg({ jsonrpc: "2.0", id: msg["id"], result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "fake" } } })
        when "notifications/initialized"
          nil
        when "tools/list", "tools/call"
          unless initialized
            write_msg({ jsonrpc: "2.0", id: msg["id"], error: { code: -32002, message: "server not initialized" } })
            next
          end
          if msg["method"] == "tools/list"
            write_msg({ jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: "listing tools" } })
            write_msg({ jsonrpc: "2.0", id: msg["id"], result: { tools: [{ name: TOOL, description: "d", inputSchema: { type: "object" } }] } })
          else
            write_msg({ jsonrpc: "2.0", id: msg["id"], result: { content: [{ type: "text", text: "result-#{TOOL}" }] } })
          end
        end
      end
    SERVER_SCRIPT
    File.write(path, template.gsub("__TOOL__", tool_name))
  end

  def test_multi_server_list_and_route
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_fake_server(a, "alpha")
      write_fake_server(b, "beta")

      mgr = Riggs::MCP::Manager.from_config(
        "srv_a" => { command: RbConfig.ruby, args: [a] },
        "srv_b" => { command: RbConfig.ruby, args: [b] }
      )

      tools = mgr.list_tools
      names = tools.map { |t| "#{t[:server]}/#{t[:name]}" }
      assert_includes names, "srv_a/alpha"
      assert_includes names, "srv_b/beta"

      assert_equal "result-alpha", mgr.call_tool("alpha", {})
      assert_equal "result-beta", mgr.call_tool("srv_b/beta", {})
      mgr.close
    end
  end

  def test_ping_reports_dead_server_as_not_ok
    mgr = Riggs::MCP::Manager.from_config(
      "dead" => { command: "riggs-nonexistent-binary-xyz", args: [] }
    )
    result = mgr.ping("dead").first
    refute result[:ok], "ping must report an unreachable server as not ok"
    assert result[:error]
  end

  def test_client_reinitializes_after_restart
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.rb")
      write_fake_server(path, "ping")
      client = Riggs::MCP::Client.new(command: RbConfig.ruby, args: [path])
      assert_equal "result-ping", client.call_tool("ping", {})
      client.close
      assert_equal "result-ping", client.call_tool("ping", {})
      client.close
    end
  end

  def test_client_stdio_without_env_flag
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.rb")
      write_fake_server(path, "ping")
      client = Riggs::MCP::Client.new(command: RbConfig.ruby, args: [path])
      tools = client.list_tools
      assert_equal "ping", tools.first["name"] || tools.first[:name]
      assert_equal "result-ping", client.call_tool("ping", {})
      client.close
    end
  end
end

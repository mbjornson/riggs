# frozen_string_literal: true

require "test_helper"
require "json"

class TestMCPClient < Minitest::Test
  def test_from_config_empty
    assert_nil Riggs::MCP::Client.from_config({})
    assert_nil Riggs::MCP::Client.from_config(nil)
  end

  def test_stdio_initialize_and_list_tools
    skip "Open3 MCP integration" unless ENV["RIGGS_MCP_INTEGRATION"]

    script = <<~'RUBY'
      require "json"
      def read_msg
        headers = {}
        loop do
          line = STDIN.gets or exit
          line = line.strip
          break if line.empty?
          k,v = line.split(":", 2)
          headers[k.strip.downcase] = v.strip
        end
        body = STDIN.read(headers["content-length"].to_i)
        JSON.parse(body)
      end
      def write_msg(obj)
        line = JSON.generate(obj)
        STDOUT.write("Content-Length: #{line.bytesize}\r\n\r\n#{line}")
        STDOUT.flush
      end
      loop do
        msg = read_msg
        if msg["method"] == "initialize"
          write_msg({ jsonrpc: "2.0", id: msg["id"], result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "fake" } } })
        elsif msg["method"] == "notifications/initialized"
          # no response
        elsif msg["method"] == "tools/list"
          write_msg({ jsonrpc: "2.0", id: msg["id"], result: { tools: [{ name: "ping" }] } })
        elsif msg["method"] == "tools/call"
          write_msg({ jsonrpc: "2.0", id: msg["id"], result: { content: [{ type: "text", text: "pong" }] } })
        end
      end
    RUBY

    path = File.join(Dir.tmpdir, "riggs_fake_mcp.rb")
    File.write(path, script)
    client = Riggs::MCP::Client.new(command: RbConfig.ruby, args: [path])
    tools = client.list_tools
    assert_equal "ping", tools.first["name"] || tools.first[:name]
    assert_equal "pong", client.call_tool("ping", {})
    client.close
  ensure
    FileUtils.rm_f(path) if path
  end
end

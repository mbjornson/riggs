# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"

module Riggs
  module MCP
    class Client
      class Error < Riggs::Error; end

      def initialize(command:, args: [], env: {})
        @command = command
        @args = Array(args)
        @env = env || {}
        @stdin = nil
        @stdout = nil
        @wait_thr = nil
        @id = 0
        @initialized = false
      end

      def start!
        return self if @wait_thr&.alive?

        @initialized = false
        @stdin, @stdout, @wait_thr = Open3.popen2(spawn_environment, @command, *@args, unsetenv_others: true)
        initialize_session!
        self
      end

      def list_tools
        start!
        res = request("tools/list", {})
        Array(res["tools"] || res[:tools])
      end

      def call_tool(name, arguments = {})
        start!
        res = request("tools/call", { name: name, arguments: arguments })
        content = res["content"] || res[:content]
        if content.is_a?(Array)
          content.map { |c| c["text"] || c[:text] || c.to_s }.join("\n")
        else
          content.to_s
        end
      end

      def close
        @stdin&.close
        @stdout&.close
        @wait_thr&.value
      rescue StandardError
        nil
      end

      private

      def spawn_environment
        declared_environment.merge("PATH" => path)
      end

      def declared_environment
        @env.transform_keys(&:to_s)
      end

      # PATH is forwarded even for an absolute command because an MCP server
      # may use a #!/usr/bin/env shebang or spawn a documented helper. No other
      # Riggs environment variable is needed by the child; every other entry is
      # named explicitly by the server declaration and is bound into its digest.
      def path
        return declared_environment["PATH"] if declared_environment.key?("PATH")

        ENV.fetch("PATH", "/bin:/usr/bin")
      end

      def initialize_session!
        return if @initialized

        request("initialize", {
                  protocolVersion: "2024-11-05",
                  capabilities: {},
                  clientInfo: { name: "riggs", version: Riggs::VERSION }
                })
        notify("notifications/initialized", {})
        @initialized = true
      end

      def request(method, params)
        @id += 1
        payload = { jsonrpc: "2.0", id: @id, method: method, params: params }
        write(payload)
        read_response(@id)
      end

      def notify(method, params)
        write({ jsonrpc: "2.0", method: method, params: params })
      end

      # MCP stdio transport: newline-delimited JSON-RPC messages.
      def write(obj)
        @stdin.write("#{JSON.generate(obj)}\n")
        @stdin.flush
      end

      def read_response(expected_id)
        loop do
          line = @stdout.gets
          raise Error, "MCP server closed unexpectedly" if line.nil?

          data = JSON.parse(line)
          next unless data.key?("id") # server notification — not our response

          raise Error, data.dig("error", "message") || "MCP error" if data["error"]
          raise Error, "Unexpected MCP id" if data["id"] != expected_id

          return data["result"] || {}
        end
      end
    end
  end
end

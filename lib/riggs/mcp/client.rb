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

      def self.from_config(servers)
        return nil if servers.nil? || servers.empty?

        _name, cfg = servers.first
        cfg = Identity.deep_symbolize(cfg)
        new(command: cfg[:command], args: cfg[:args] || [], env: cfg[:env] || {})
      end

      def start!
        return self if @wait_thr&.alive?

        @initialized = false
        @stdin, @stdout, @wait_thr = Open3.popen2(@env.transform_keys(&:to_s), @command, *@args)
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

# frozen_string_literal: true

require_relative "client"

module Riggs
  module MCP
    class Manager
      def self.from_config(servers)
        return new({}) if servers.nil? || servers.empty?

        configs = Identity.deep_symbolize(servers)
        new(configs)
      end

      def self.wrap_client(client, name: "default")
        mgr = new({})
        mgr.instance_variable_set(:@clients, { name.to_s => client })
        mgr.instance_variable_set(:@configs, { name.to_s => {} })
        mgr
      end

      def initialize(configs = {})
        @configs = configs.transform_keys(&:to_s)
        @clients = {}
      end

      def server_names
        @configs.keys.sort
      end

      def list_tools(servers: nil)
        names = servers ? Array(servers).map(&:to_s) : server_names
        names.flat_map do |server|
          client = client_for(server)
          next [] unless client

          Array(client.list_tools).map do |t|
            h = t.is_a?(Hash) ? t.transform_keys(&:to_s) : {}
            {
              server: server,
              name: (h["name"] || h[:name]).to_s,
              description: (h["description"] || h[:description] || "").to_s,
              input_schema: h["inputSchema"] || h["input_schema"] || h[:input_schema] || {}
            }
          end
        rescue StandardError => e
          warn "MCP server '#{server}' list_tools failed: #{e.message}"
          []
        end
      end

      def call_tool(name, arguments = {}, server: nil)
        server_name, tool_name = resolve_tool(name, server: server)
        client = client_for(server_name)
        raise Client::Error, "No MCP server for tool '#{name}'" unless client

        client.call_tool(tool_name, arguments)
      end

      def ping(server = nil)
        targets = server ? [server.to_s] : server_names
        targets.map do |s|
          client = client_for(s)
          raise Client::Error, "unknown MCP server '#{s}'" unless client

          { server: s, ok: true, tool_count: Array(client.list_tools).size }
        rescue StandardError => e
          { server: s, ok: false, error: e.message }
        end
      end

      def close
        @clients.each_value(&:close)
        @clients.clear
      end

      private

      def client_for(server)
        key = server.to_s
        return @clients[key] if @clients.key?(key)

        cfg = @configs[key]
        return nil unless cfg

        client = Client.new(
          command: cfg[:command],
          args: cfg[:args] || [],
          env: cfg[:env] || {}
        )
        @clients[key] = client
        client
      end

      def resolve_tool(name, server: nil)
        raw = name.to_s
        return [server.to_s, raw.sub(%r{\A#{Regexp.escape(server.to_s)}/}, "")] if server

        if raw.include?("/")
          s, t = raw.split("/", 2)
          return [s, t]
        end

        # Unique name across servers
        matches = list_tools.select { |t| t[:name] == raw }
        raise Client::Error, "Unknown MCP tool '#{raw}'" if matches.empty?
        if matches.size > 1
          raise Client::Error, "Ambiguous MCP tool '#{raw}' — use server/tool (candidates: #{matches.map do |m|
            "#{m[:server]}/#{m[:name]}"
          end.join(', ')})"
        end

        [matches.first[:server], matches.first[:name]]
      end
    end
  end
end

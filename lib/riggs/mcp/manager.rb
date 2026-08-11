# frozen_string_literal: true

require_relative "../trust"
require_relative "approval"
require_relative "client"

module Riggs
  module MCP
    class Manager
      # `provenance:` is REQUIRED, with no default. A caller that forgets it
      # then gets an ArgumentError at construction rather than an ungated spawn
      # later -- which is what a default of {} bought the first draft of this
      # plan. Ruby enforces the thing a code comment cannot.
      def self.from_config(servers, provenance:, trust: nil, project_path: nil, interactive: false)
        configs = configs_for(servers)
        new(configs, provenance: provenance, trust: trust, project_path: project_path, interactive: interactive)
      end

      def self.configs_for(servers)
        return {} if servers.nil? || servers.empty?

        Identity.deep_symbolize(servers)
      end

      def self.wrap_client(client, name: "default")
        # This injects an in-process object from GraphEngine, not configuration.
        # It performs no approval and must never be reachable from configuration.
        mgr = new({}, provenance: {})
        mgr.instance_variable_set(:@clients, { name.to_s => client })
        mgr.instance_variable_set(:@configs, { name.to_s => {} })
        mgr
      end

      def initialize(configs = {}, provenance:, trust: nil, project_path: nil, interactive: false)
        @configs = configs.transform_keys(&:to_s)
        @provenance = (provenance || {}).transform_keys(&:to_s)
        @trust = trust
        @project_path = project_path
        @interactive = interactive
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
        rescue NotApproved
          raise
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
        rescue NotApproved
          raise
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
          command: ensure_approved!(key, cfg),
          args: cfg[:args] || [],
          env: cfg[:env] || {}
        )
        @clients[key] = client
        client
      end

      # The one place a configured name becomes a spawned process. A server
      # the global tier defined is the operator's own; one a repo introduced
      # is not, and is approved separately from the directory itself so a
      # later commit cannot add a command under an existing trust grant.
      #
      # FAILS CLOSED. The first draft returned early when provenance, trust or
      # project_path was missing, so any Manager built without them -- and
      # there are four from_config call sites in commands.rb alone
      # (338, 383, 516, 535) -- spawned project servers ungated. A construction
      # that cannot answer "did a repo introduce this?" must refuse, not
      # assume no.
      def ensure_approved!(name, cfg)
        # Resolve for BOTH tiers. A global server spawned by bare name still
        # re-consults PATH inside popen2, so "the resolved path is what gets
        # spawned" would have been false for exactly the servers the operator
        # trusts most. Resolution is not an approval; it is just naming the
        # file precisely.
        resolved = Trust.resolve_executable(command: cfg[:command], env: cfg[:env] || {})
        return resolved if @provenance[name] == :global

        raise_missing_provenance!(name) unless @provenance.key?(name)
        raise_missing_approval_context!(name) unless @trust && @project_path

        approve_or_raise!(name, cfg, resolved)
      end

      def approve_or_raise!(name, cfg, resolved)
        digest = approval_digest(resolved, cfg)
        return resolved if @trust.mcp_approved?(@project_path, name, digest)
        return resolved if @interactive && approve_from_prompt(name, cfg, digest) == :approved

        raise NotApproved, not_approved_message(name, cfg)
      end

      # Digest the path ALREADY resolved above, not the bare command -- which
      # would make Trust.digest resolve a second time, and a filesystem or
      # PATH change between the two calls could approve binary B while
      # spawning binary A. One resolution, used for both.
      def approval_digest(resolved, cfg)
        Trust.digest(command: resolved, args: cfg[:args] || [], env: cfg[:env] || {})
      end

      def raise_missing_provenance!(name)
        raise NotApproved, "MCP server '#{name}' has no recorded tier. Build the Manager with " \
                           "provenance: from Identity.resolved so approval can be decided."
      end

      def raise_missing_approval_context!(name)
        raise NotApproved, "MCP server '#{name}' is project-declared but this Manager was built " \
                           "without trust:/project_path:, so approval cannot be checked."
      end

      def not_approved_message(name, cfg)
        <<~MESSAGE.chomp
          MCP server '#{name}' is declared by this project and is not approved.
            #{Approval.redact(cfg[:command], cfg[:args] || [])}
          Run: riggs mcp:approve #{name}
        MESSAGE
      end

      def approve_from_prompt(name, cfg, digest)
        warn "⚠ project declares MCP server '#{name}'"
        warn "  #{Approval.redact(cfg[:command], cfg[:args] || [])}"
        warn "  approve? [y/N]"
        return :declined unless %w[y yes].include?($stdin.gets.to_s.strip.downcase)

        @trust.approve_mcp!(@project_path, name, digest)
        :approved
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

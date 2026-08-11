# frozen_string_literal: true

require_relative "../config/resolver"
require_relative "../trust"

module Riggs
  class CLI < Thor
    class TrustCommands
      def initialize(trust:, io:)
        @trust = trust
        @io = io
      end

      def grant!(project_path)
        @trust.grant!(project_path)
        @io.puts "✅ Trusted project: #{project_path}"
      end

      def list
        projects = @trust.projects
        return @io.puts("📭 No trusted projects.") if projects.empty?

        projects.each { |path| @io.puts(entry(path)) }
      end

      # `riggs trust` grants the path Config::Resolver resolved, which is a
      # realpath. Comparing the raw argument made every equivalent spelling of
      # the same directory -- a trailing slash, a `..` segment, a symlink --
      # report "Nothing to remove" while the grant stayed in place. A
      # revocation command that says there was nothing to revoke is worse than
      # one that fails, because the operator stops looking.
      #
      # The raw argument is still tried, second: a stale entry whose directory
      # is gone is exactly what trust:list exists to surface, and it must stay
      # forgettable.
      def forget!(project_path)
        forgotten = @trust.forget!(canonical(project_path)) || @trust.forget!(project_path)
        return @io.puts("ℹ️  Nothing to remove for #{project_path}") if forgotten.nil?

        @io.puts "✅ Forgot trust for #{forgotten}"
      end

      private

      # ProjectPaths' own canonicalization, not a second copy of it -- and
      # deliberately NOT Config::Resolver.project_path, which walks up to the
      # enclosing repository. Walking up would let `trust:forget <repo>/typo`
      # resolve to <repo> and revoke a grant the operator never named.
      def canonical(path)
        Config::ProjectPaths.canonical_path(path)
      end

      def entry(path)
        return "• #{path}" if Dir.exist?(path)

        "• #{path} (missing)"
      end
    end

    class MCPApproval
      Selection = Struct.new(:server, :tier, keyword_init: true)

      def initialize(trust:, resolved:, io:)
        @trust = trust
        @resolved = resolved
        @io = io
      end

      def approve!(name)
        selected = selected_server(name)
        raise Error, "MCP server '#{name}' is not configured." if selected.nil?
        raise Error, "MCP server '#{name}' is declared in the global tier; nothing to approve." if selected.tier == :global

        approve_selected!(name, selected.server)
      end

      private

      def approve_selected!(name, server)
        @trust.approve_mcp!(@resolved.project_path, name, digest(server))
        @io.puts "✅ Approved MCP server '#{name}' for #{@resolved.project_path}"
      end

      def selected_server(name)
        from_resolved(name) || from_project_file(name)
      end

      def from_resolved(name)
        server = lookup(merged_servers, name)
        return nil if server.nil?

        Selection.new(server: server, tier: tier(name))
      end

      # mcp:approve is the explicit operator command for this declaration.
      # It still consults the project file to locate the server by name, then
      # lets Trust#approve_mcp! enforce that trust was granted first.
      def from_project_file(name)
        server = lookup(project_servers, name)
        return nil if server.nil?

        Selection.new(server: server, tier: :project)
      end

      def merged_servers
        servers = @resolved.config[:mcp_servers]
        return {} unless servers.is_a?(Hash)

        servers
      end

      def project_servers
        path = Config::ProjectConfig.new(@resolved.project_path).path
        return {} if path.nil? || !File.exist?(path)

        loaded = Identity.load_file!(path)
        servers = loaded[:mcp_servers]
        return {} unless servers.is_a?(Hash)

        servers
      end

      def tier(name)
        levels = @resolved.provenance[:mcp_servers] || {}
        found = lookup(levels, name)
        return :project if found.nil?

        found
      end

      # Mirror MCP::Manager#ensure_approved!: resolve once, then digest that
      # concrete path with args/env, so CLI approvals and runtime gate checks
      # compare the same identity.
      def digest(server)
        env = env_for(server)
        resolved = Trust.resolve_executable(command: command_for(server), env: env)
        Trust.digest(command: resolved, args: args_for(server), env: env)
      end

      def command_for(server)
        server[:command] || server["command"]
      end

      def args_for(server)
        server[:args] || server["args"] || []
      end

      def env_for(server)
        server[:env] || server["env"] || {}
      end

      def lookup(mapping, name)
        mapping[name.to_sym] || mapping[name.to_s]
      end
    end
  end
end

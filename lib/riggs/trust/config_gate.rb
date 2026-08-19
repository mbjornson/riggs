# frozen_string_literal: true

require_relative "fingerprint"

module Riggs
  class Trust
    # The read-time gate on a project configuration file. Two questions, asked
    # in one place: is this path trusted, and are these the bytes that were
    # trusted. The global tier is operator-owned and answers neither -- it is
    # the file the operator writes, not one a repository ships.
    class ConfigGate
      def self.default
        new(trust: Trust.default, io: $stderr, stdin: $stdin)
      end

      def initialize(trust:, io:, stdin:)
        @trust = trust
        @io = io
        @stdin = stdin
      end

      # Entry point for a path whose tier is not yet known.
      def ensure_file!(config_path)
        return true if global?(config_path)

        ensure!(Config::Resolver.project_path(File.dirname(config_path)), config_path)
      end

      # Raises unless the project is trusted AND its config still matches the
      # recorded fingerprint. On a TTY the operator is asked once instead.
      def ensure!(project_path, config_path)
        return true if @trust.config_current?(project_path, config_path)
        return true if granted_at_prompt?(project_path, config_path)

        raise Error, refusal(config_path)
      end

      private

      def global?(config_path)
        File.expand_path(config_path) == File.expand_path(Config::Resolver.global_config)
      end

      def granted_at_prompt?(project_path, config_path)
        return false unless tty? && confirmed?(config_path)

        @trust.grant!(project_path)
        @trust.record_config!(project_path, config_path)
        @io.puts "   Trusted. Re-run `riggs trust` after editing this file."
        true
      end

      def tty?
        @stdin.respond_to?(:tty?) && @stdin.tty?
      end

      def confirmed?(config_path)
        @io.puts "⚠  Project config is not trusted."
        @io.puts "   Path: #{File.expand_path(config_path)}"
        @io.puts "   Trusting allows this file to define users, roles, and MCP commands."
        @io.print "   Trust this project's config? [y/N] "
        @stdin.gets.to_s.strip.match?(/\Ay(es)?\z/i)
      end

      def refusal(config_path)
        "Project not trusted (#{File.expand_path(config_path)}). " \
          "Review the file, then run `riggs trust`."
      end
    end
  end
end

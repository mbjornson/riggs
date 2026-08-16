# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module Riggs
  # Input-loading guard for project-local `.agent_hubrc`. Not a sandbox: once
  # trusted, MCP commands still run as the operator's user. Trust answers only
  # "may this file define principals and MCP servers?".
  class ProjectTrust
    STORE_NAME = "trusted_projects.json"

    def self.home
      ENV.fetch("RIGGS_TRUST_HOME") { File.expand_path("~/.riggs") }
    end

    def self.store_path
      File.join(home, STORE_NAME)
    end

    def self.fingerprint(config_path)
      Digest::SHA256.hexdigest(File.binread(config_path))
    end

    def self.trusted?(project_root, config_path:)
      return false unless config_path && File.exist?(config_path)

      entry = load_store[normalize_root(project_root)]
      return false unless entry.is_a?(Hash)

      entry["fingerprint"] == fingerprint(config_path) &&
        entry["config_path"] == File.expand_path(config_path)
    end

    def self.trust!(project_root, config_path:)
      raise Error, "Missing config at #{config_path}" unless config_path && File.exist?(config_path)

      root = normalize_root(project_root)
      store = load_store
      store[root] = {
        "fingerprint" => fingerprint(config_path),
        "config_path" => File.expand_path(config_path),
        "trusted_at" => Time.now.utc.iso8601
      }
      write_store!(store)
      root
    end

    # Raises unless the project config is trusted. On a TTY, prompts once.
    def self.ensure!(project_root, config_path:, io: $stderr, stdin: $stdin)
      return true if trusted?(project_root, config_path: config_path)

      if stdin.respond_to?(:tty?) && stdin.tty?
        io.puts "⚠  Project .agent_hubrc is not trusted."
        io.puts "   Path: #{File.expand_path(config_path)}"
        io.puts "   Trusting allows this file to define users, roles, and MCP commands."
        io.print "   Trust this project's .agent_hubrc? [y/N] "
        answer = stdin.gets.to_s.strip
        if answer.match?(/\Ay(es)?\z/i)
          trust!(project_root, config_path: config_path)
          io.puts "   Trusted. Re-run trust after editing .agent_hubrc."
          return true
        end
      end

      raise Error,
            "Project not trusted (#{File.expand_path(config_path)}). " \
            "Review the file, then run `riggs trust`."
    end

    def self.normalize_root(project_root)
      File.expand_path(project_root || Dir.pwd)
    end

    def self.load_store
      path = store_path
      return {} unless File.exist?(path)

      raw = JSON.parse(File.read(path))
      raw.is_a?(Hash) ? raw : {}
    rescue JSON::ParserError
      {}
    end

    def self.write_store!(store)
      FileUtils.mkdir_p(home)
      File.write(store_path, JSON.pretty_generate(store))
    end
    private_class_method :load_store, :write_store!
  end
end

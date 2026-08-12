# frozen_string_literal: true

require "psych"
require_relative "config/resolver"
require_relative "config/merge"

module Riggs
  class Identity
    Resolved = Struct.new(:config, :provenance, :project_path, :project_config_path,
                          :trusted, :legacy, keyword_init: true)

    DEFAULT_ROLES = {
      # run_owned_workflow, not run_workflow: a PM runs the workflows a PM
      # owns -- PRD review, triage, roadmap -- and not delivery, security or
      # infrastructure ones, which carry another role's owner_role.
      pm: %w[edit_workflow manage_skills configure_memory publish read_workflow inspect_run run_owned_workflow],
      engineer: %w[run_workflow approve_gates read_workflow inspect_run manage_mcp],
      viewer: %w[read_workflow inspect_run]
    }.freeze

    # Resolve the real path first. Passing the nil-defaulted parameter
    # straight through made every production merge diagnostic name a
    # placeholder instead of the actual file -- the same defect as
    # config_path's nil, one method over.
    def self.resolved(cwd: Dir.pwd, trust: nil, global_config: nil)
      gc = global_config || Config::Resolver.global_config
      resolver_result = Config::Resolver.new(cwd: cwd, trust: trust, global_config: gc).resolve
      merged = Config::Merge.call(
        global: resolver_result.global, project: resolver_result.project,
        global_path: gc, project_path: resolver_result.project_config_path || resolver_result.project_path
      )
      Resolved.new(
        config: merged.config, provenance: merged.provenance, project_path: resolver_result.project_path,
        project_config_path: resolver_result.project_config_path, trusted: resolver_result.trusted,
        legacy: resolver_result.legacy
      )
    end

    # The path a human should edit for project-scoped settings. Falls through
    # to the global config when there is no TRUSTED project tier -- Resolver
    # returns nil for project_config_path on an untrusted path, so this can
    # never hand ConfigStore a file the resolver declined to open.
    #
    # `global_config` is resolved here, not defaulted to nil, because the body
    # calls File.exist? on it and every zero-argument caller would otherwise
    # raise TypeError -- including lib/riggs/web/app.rb:98.
    def self.config_path(cwd: Dir.pwd, trust: nil, global_config: nil)
      gc = global_config || Config::Resolver.global_config
      resolver_result = Config::Resolver.new(cwd: cwd, trust: trust, global_config: gc).resolve
      if resolver_result.project_config_path
        resolver_result.project_config_path
      elsif File.exist?(gc)
        gc
      end
    end

    # Unchanged contract: a symbolized hash. With no explicit path it is now
    # the merged two-tier result, which is why the eleven production call
    # sites and every hub_config: in the suite need no change.
    def self.load_config(path = nil, cwd: Dir.pwd, trust: nil, global_config: nil)
      return load_file!(path) if path

      result = resolved(cwd: cwd, trust: trust, global_config: global_config)
      raise_missing_config!(result.config)
      result.config
    end

    def self.load_file!(path)
      raise Error, "Missing config at #{path}. Run 'riggs setup' first." unless File.exist?(path)

      raw = Psych.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
      deep_symbolize(raw)
    end

    # project_path is carried on the identity so the session column and the
    # memory namespace read ONE resolution. Callers that already resolved it --
    # the CLI holds it on current_resolved -- pass it in rather than asking
    # again; the default is the same pure function, keyed by the same cwd.
    def self.resolve(cli_user: nil, config: nil, project_path: nil)
      cfg = config || load_config
      raw = cli_user || cfg[:default_user]
      raise Error, "No user specified and no default_user in .agent_hubrc" if raw.nil? || raw.to_s.empty?

      user_key = raw.to_s
      users = cfg[:users] || {}
      user_cfg = users[user_key.to_sym] || users[user_key]
      raise Error, "User '#{user_key}' not found in .agent_hubrc" unless user_cfg

      role = (user_cfg[:role] || user_cfg["role"]).to_s.to_sym
      roles = cfg[:roles] || {}
      permissions = Array(roles[role] || roles[role.to_s] || DEFAULT_ROLES[role] || [])

      {
        id: (user_cfg[:id] || user_cfg["id"] || user_key).to_s,
        name: (user_cfg[:name] || user_cfg["name"] || user_key).to_s,
        role: role,
        github_username: user_cfg[:github_username] || user_cfg["github_username"],
        memory_namespace: (user_cfg[:memory_namespace] || user_cfg["memory_namespace"] || user_key).to_s,
        project_path: project_path || Config::Resolver.project_path,
        permissions: permissions.map(&:to_s)
      }
    end

    def self.permitted?(identity, *needed)
      needed.flatten.map(&:to_s).all? { |p| identity[:permissions].include?(p) }
    end

    def self.deep_symbolize(obj)
      IdentitySymbolizer.call(obj)
    end

    def self.raise_missing_config!(config)
      return unless config.empty?

      raise Error, "No riggs configuration found. Run 'riggs setup' to create ~/.riggs/config.yml."
    end
  end

  class IdentitySymbolizer
    def self.call(obj)
      return symbolize_hash(obj) if obj.is_a?(Hash)
      return obj.map { |value| call(value) } if obj.is_a?(Array)

      obj
    end

    def self.symbolize_hash(hash)
      hash.each_with_object({}) do |(key, value), result|
        result[symbolize_key(key)] = call(value)
      end
    end

    def self.symbolize_key(key)
      return key if key.is_a?(Symbol)

      key.to_s.to_sym
    end
  end
end

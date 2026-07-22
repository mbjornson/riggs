# frozen_string_literal: true

require "psych"

module Riggs
  class Identity
    CONFIG_CANDIDATES = [".agent_hubrc", "./config/.agent_hubrc", "./config/agent_hubrc"].freeze

    DEFAULT_ROLES = {
      pm: %w[edit_workflow manage_skills configure_memory publish read_workflow inspect_run],
      engineer: %w[run_workflow approve_gates read_workflow inspect_run manage_mcp],
      viewer: %w[read_workflow inspect_run]
    }.freeze

    def self.config_path
      CONFIG_CANDIDATES.find { |p| File.exist?(p) }
    end

    def self.load_config(path = nil)
      path ||= config_path
      raise Error, "Missing .agent_hubrc. Run 'riggs setup' first." unless path && File.exist?(path)

      raw = Psych.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
      deep_symbolize(raw)
    end

    def self.resolve(cli_user: nil, config: nil)
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
        permissions: permissions.map(&:to_s)
      }
    end

    def self.permitted?(identity, *needed)
      needed.flatten.map(&:to_s).all? { |p| identity[:permissions].include?(p) }
    end

    def self.deep_symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          h[k.is_a?(Symbol) ? k : k.to_s.to_sym] = deep_symbolize(v)
        end
      when Array
        obj.map { |v| deep_symbolize(v) }
      else
        obj
      end
    end
  end
end

# frozen_string_literal: true

require "time"
require_relative "trust/executable"
require_relative "trust/digest"
require_relative "trust/store"

module Riggs
  # Which absolute paths the operator has trusted, and which MCP servers they
  # have approved within each.
  #
  # Nothing secret is ever stored here. Approvals are recorded as a digest of
  # the command, its arguments, and the NAMES of forwarded environment
  # variables. Values are never read into the digest and never written.
  class Trust
    # Resolved at call time, not as a load-time constant, so a test -- and an
    # operator with more than one riggs install -- can point the whole global
    # tier somewhere else. The same escape hatch CODEX_HOME provides.
    def self.home
      ENV["RIGGS_HOME"] || File.join(Dir.home, ".riggs")
    end

    def self.default_path
      File.join(home, "trust.yml")
    end

    def self.default
      new(path: default_path)
    end

    def self.digest(command:, args:, env:)
      Digest.of(command: command, args: args, env: env)
    end

    def self.resolve_executable(command:, env:)
      Executable.resolve(command: command, env: env)
    end

    # `path` is required and has no default. A caller that forgets it raises
    # ArgumentError instead of quietly writing to the developer's real
    # ~/.riggs/trust.yml. Production callers use .default.
    def initialize(path:)
      @store = Store.new(path: path)
    end

    def path
      @store.path
    end

    # Trust is `trusted_at` being PRESENT, not an entry existing. An entry is
    # also created by recording an approval, and conflating the two would mean
    # approving one MCP server silently trusts the whole project config --
    # collapsing the two gates this phase exists to separate.
    def trusted?(project_path)
      !trusted_at(project_path).nil?
    end

    def trusted_at(project_path)
      entry(project_path)&.fetch("trusted_at", nil)
    end

    def grant!(project_path)
      update { |data| project_entry(data, project_path)["trusted_at"] ||= now }
      project_path.to_s
    end

    # Returns the path it forgot, or nil when there was nothing to forget.
    # Deliberately not a boolean, and deliberately not `forget?`: this deletes
    # an entry and rewrites the file, and `?` reads as a pure query.
    def forget!(project_path)
      data = @store.read
      return nil if projects_in(data).delete(project_path.to_s).nil?

      @store.write(data)
      project_path.to_s
    end

    def projects
      projects_in(@store.read).keys.sort
    end

    # The nil check is separate from the comparison on purpose: collapsing this
    # to `recorded(...) == digest` makes an unrecorded server compare equal to
    # a nil digest, which approves it.
    def mcp_approved?(project_path, name, digest)
      found = recorded(project_path, name)
      !found.nil? && found == digest
    end

    # Approving requires trust first: the declaration being approved lives in a
    # file that may not be read yet. This never writes trusted_at.
    def approve_mcp!(project_path, name, digest)
      require_trust!(project_path, name)
      update { |data| approvals(data, project_path)[name.to_s] = digest }
      digest
    end

    private

    def recorded(project_path, name)
      entry(project_path)&.dig("mcp_approved", name.to_s)
    end

    def require_trust!(project_path, name)
      return if trusted?(project_path)

      raise Error, "cannot approve MCP server '#{name}' for #{project_path}: " \
                   "the path is not trusted. Run 'riggs trust' there first."
    end

    def approvals(data, project_path)
      project_entry(data, project_path)["mcp_approved"] ||= {}
    end

    def project_entry(data, project_path)
      projects_in(data)[project_path.to_s] ||= {}
    end

    def projects_in(data)
      data["projects"] ||= {}
    end

    def entry(project_path)
      projects_in(@store.read)[project_path.to_s]
    end

    def update
      data = @store.read
      yield data
      @store.write(data)
    end

    def now
      Time.now.utc.iso8601
    end
  end
end

# frozen_string_literal: true

require "fileutils"
require "psych"
require_relative "../config/resolver"
require_relative "../storage"
require_relative "../trust"

module Riggs
  class CLI < Thor
    class Setup
      def initialize(riggs_home:, cwd:)
        @riggs_home = riggs_home
        @cwd = cwd
      end

      def call
        puts "🔧 Starting Riggs setup…"
        prepare_global_tier
        prepare_project_tier
        record_trust
        puts "\n🎉 Riggs setup complete!"
      end

      private

      def prepare_global_tier
        GlobalTier.new(riggs_home: @riggs_home, project_path: project_path).call
      end

      def prepare_project_tier
        ProjectTier.new(riggs_home: @riggs_home, project_path: project_path).call
      end

      def record_trust
        Trust.new(path: File.join(@riggs_home, "trust.yml")).grant!(project_path)
        puts "✅ Recorded trust for #{project_path}"
      end

      def project_path
        @project_path ||= Config::Resolver.project_path(@cwd)
      end
    end

    # This collaborator owns the global tier so Setup remains an ordered,
    # readable account of an operator's first Riggs experience.
    class GlobalTier
      def initialize(riggs_home:, project_path:)
        @riggs_home = riggs_home
        @project_path = project_path
      end

      def call
        ensure_directories
        create_config
        prepare_database
      end

      private

      def ensure_directories
        [riggs_home, skills_path, workflows_path].each { |path| FileUtils.mkdir_p(path) }
        puts "✅ Created dirs: #{riggs_home}, #{skills_path}, #{workflows_path}"
      end

      def create_config
        return keep_config if File.exist?(config_path)

        write_config
      end

      def keep_config
        puts "⏭️  Keeping existing #{config_path}"
      end

      def write_config
        write_seed(LegacySeed.new(default_config, legacy_path).seed)
      end

      def write_seed(seed)
        # Write it and File.chmod(0o600, path) -- R11.1 requires it of every
        # writer, not only the trust registry.
        File.write(config_path, Psych.dump(seed.config))
        File.chmod(0o600, config_path)
        report_creation(seed)
      end

      def report_creation(seed)
        puts "✅ Created #{config_path}#{seed_message(seed)}"
        seed.dropped.each { |key| puts "⚠️  Dropped provider key: #{key}" }
      end

      # Describes the SEED, not the file. "(empty global config)" was printed
      # over a file holding a default_user, three users, roles and providers --
      # the first line a new operator reads, telling them the thing that just
      # worked had not.
      def seed_message(seed)
        return " (defaults; no legacy config to seed from)" unless seed.source?

        " (seeded from #{legacy_path})"
      end

      def prepare_database
        Storage.new(db_path: global_database_path).close
        puts "✅ Database ready at #{global_database_path}"
      end

      def global_database_path
        Psych.safe_load(File.read(config_path), aliases: true).fetch("sqlite_path")
      end

      def default_config
        DefaultConfig.new(riggs_home: @riggs_home).config
      end

      def legacy_path
        Config::ProjectConfig.new(@project_path).path
      end

      attr_reader :riggs_home

      def config_path
        File.join(riggs_home, "config.yml")
      end

      def skills_path
        File.join(riggs_home, "skills")
      end

      def workflows_path
        File.join(riggs_home, "workflows")
      end
    end

    class LegacySeed
      PROVIDER_FIELDS = %w[type model base_url pricing relay_chain auth].freeze
      Result = Struct.new(:config, :dropped, :source?, keyword_init: true)

      def initialize(config, path)
        @config = config
        @path = path
      end

      def seed
        return Result.new(config: @config, dropped: [], source?: false) unless legacy?

        Result.new(config: seed_people, dropped: dropped_provider_keys, source?: true)
      end

      private

      def seed_people
        legacy = Psych.safe_load(File.read(@path), aliases: true) || {}
        @config.merge(legacy.slice("users", "roles")).merge("providers" => seeded_providers(legacy))
      end

      # PROVIDER_FIELDS is written out instead of borrowing
      # Config::Merge::PROVIDER_FIELDS. The two lists answer different
      # questions and have already diverged: Config::Merge::PROVIDER_FIELDS is
      # what a PROJECT may set, and it excludes base_url and pricing because
      # those are operator-owned. Seeding writes into the operator's OWN global
      # tier, where both belong, so borrowing that constant would silently drop
      # the endpoint and prices out of a legacy config during the very step
      # meant to preserve it.
      def seeded_providers(legacy)
        legacy.fetch("providers", {}).transform_values { |provider| provider.slice(*PROVIDER_FIELDS) }
      end

      # Every other provider key is dropped and printed by name. A legacy
      # .agent_hubrc may well carry an api_key, and copying providers wholesale
      # would persist it in ~/.riggs/config.yml -- breaking "no tier holds
      # credentials" through the very step meant to adopt the new layout.
      def dropped_provider_keys
        legacy_providers.flat_map { |_name, provider| provider.keys - PROVIDER_FIELDS }.uniq.sort
      end

      def legacy_providers
        legacy = Psych.safe_load(File.read(@path), aliases: true) || {}
        legacy.fetch("providers", {})
      end

      def legacy?
        @path && File.exist?(@path)
      end
    end

    class DefaultConfig
      def initialize(riggs_home:)
        @riggs_home = riggs_home
      end

      def config
        { "default_user" => "pm_alice", "users" => users, "roles" => roles, "sqlite_path" => database_path,
          "sqlite_memory" => sqlite_memory, "providers" => providers, "mcp_servers" => {} }
      end

      private

      def users
        { "pm_alice" => pm_alice, "eng_bob" => eng_bob, "view_cara" => view_cara }
      end

      def pm_alice
        person("pm_alice", name: "Alice PM", role: "pm", github_username: "@alicepm", memory_namespace: "team_shared")
      end

      def eng_bob
        person("eng_bob", name: "Bob Eng", role: "engineer", github_username: "@bobbuilder", memory_namespace: "eng_bob_private")
      end

      def view_cara
        person("view_cara", name: "Cara Viewer", role: "viewer", memory_namespace: "readonly")
      end

      def person(id, attributes)
        person = attributes.merge("id" => id)
        person.delete(:github_username) unless person[:github_username]
        person.transform_keys(&:to_s)
      end

      def roles
        { "pm" => %w[edit_workflow manage_skills configure_memory publish read_workflow inspect_run],
          "engineer" => engineer_permissions, "viewer" => %w[read_workflow inspect_run] }
      end

      def engineer_permissions
        %w[run_workflow approve_gates read_workflow inspect_run manage_mcp]
      end

      def database_path
        File.join(@riggs_home, "riggs.sqlite3")
      end

      def sqlite_memory
        { "vector_path" => ENV.fetch("RIGGS_VECTOR_EXT", nil), "memory_path" => ENV.fetch("RIGGS_MEMORY_EXT", nil),
          "embed_model" => ENV.fetch("RIGGS_EMBED_MODEL", nil) }
      end

      def providers
        { "mock" => { "type" => "mock" }, "claude" => { "type" => "anthropic" }, "openai" => { "type" => "openai" },
          "ollama" => { "type" => "ollama", "base_url" => "http://127.0.0.1:11434/v1", "model" => "llama3" },
          "cursor" => { "type" => "cursor" }, "claude_cli" => { "type" => "claude_cli" }, "codex" => { "type" => "codex" },
          "cursor_cloud" => cursor_cloud }
      end

      def cursor_cloud
        { "type" => "cursor_cloud", "model" => "composer-2.5", "repos" => [], "poll_interval_seconds" => 5 }
      end
    end

    class ProjectTier
      def initialize(riggs_home:, project_path:)
        @riggs_home = riggs_home
        @project_path = project_path
      end

      def call
        return if global_tier_project?

        ensure_directories
        install_examples
        write_skeleton
      end

      private

      # Asks the question the guard is actually for -- would the project
      # skeleton be written over the global config? -- rather than the proxy it
      # used to compare (project_path == home). The proxy only held while the
      # global tier lived at ~/.riggs; with RIGGS_HOME pointing elsewhere, the
      # two paths can collide without the project being the home directory, and
      # can differ while it is.
      def global_tier_project?
        File.expand_path(File.join(@project_path, ".riggs")) == File.expand_path(@riggs_home)
      end

      def ensure_directories
        [workflows_path, skills_path].each { |path| FileUtils.mkdir_p(path) }
      end

      # Copy example playbook + skill into the project if missing.
      def install_examples
        ExampleInstaller.new(workflows_path: workflows_path, skills_path: skills_path).call
      end

      def write_skeleton
        return if File.exist?(config_path)

        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, skeleton)
        puts "✅ Created #{config_path}"
      end

      # Commenting every key is what makes it both a useful template and unable
      # to trip a hard error; the spec's earlier "no users or roles" wording is
      # superseded by R11.8's allowlist.
      def skeleton
        Config::Merge::PROJECT_KEYS.map { |key| "# #{key}:\n" }.join
      end

      def config_path
        File.join(@project_path, ".riggs", "config.yml")
      end

      def workflows_path
        File.join(@project_path, "config", "riggs", "workflows")
      end

      def skills_path
        File.join(@project_path, "config", "riggs", "skills")
      end
    end

    class ExampleInstaller
      def initialize(workflows_path:, skills_path:)
        @workflows_path = workflows_path
        @skills_path = skills_path
      end

      def call
        install_workflow
        install_skill
      end

      private

      def install_workflow
        copy(workflow_source, File.join(@workflows_path, "example_triage.yml"))
      end

      def install_skill
        copy(skill_source, File.join(@skills_path, "triage_v1", "SKILL.yml"))
      end

      def copy(source, destination)
        return unless File.exist?(source) && !File.exist?(destination)

        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
        puts "✅ Installed example playbook → #{destination}" if destination.end_with?("example_triage.yml")
      end

      def workflow_source
        File.expand_path("../../../config/riggs/workflows/example_triage.yml", __dir__)
      end

      def skill_source
        File.expand_path("../../../config/riggs/skills/triage_v1/SKILL.yml", __dir__)
      end
    end
  end
end

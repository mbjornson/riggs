# frozen_string_literal: true

require "thor"
require "psych"
require "fileutils"
require "json"
require_relative "../identity"
require_relative "../workflow/loader"
require_relative "../workflow/graph_engine"
require_relative "../memory/service"
require_relative "../storage"
require_relative "../skills/registry"
require_relative "../mcp/client"
require_relative "../providers/router"

module Riggs
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    class_option :user, type: :string, desc: "Override default user from .agent_hubrc"

    map "identity:show" => :identity_show
    map "workflow:new" => :workflow_new
    map "workflow:validate" => :workflow_validate
    map "workflow:simulate" => :workflow_simulate
    map "workflow:run" => :workflow_run
    map "workflow:inspect" => :workflow_inspect
    map "memory:recall" => :memory_recall
    map "memory:persist" => :memory_persist
    map "skills:list" => :skills_list
    map "providers:ping" => :providers_ping

    desc "setup", "Create .agent_hubrc, db/, config/riggs/workflows/, and SQLite database."
    def setup
      require "sqlite3"

      puts "🔧 Starting Riggs setup…"
      base_dir = Dir.pwd
      db_dir = File.expand_path("db", base_dir)
      workflows_dir = File.expand_path("config/riggs/workflows", base_dir)
      skills_dir = File.expand_path("config/riggs/skills", base_dir)

      [db_dir, workflows_dir, skills_dir].each { |d| FileUtils.mkdir_p(d) }
      puts "✅ Created dirs: #{db_dir}, #{workflows_dir}, #{skills_dir}"

      hub_cfg = {
        "default_user" => "pm_alice",
        "users" => {
          "pm_alice" => {
            "id" => "pm_alice",
            "name" => "Alice PM",
            "role" => "pm",
            "github_username" => "@alicepm",
            "memory_namespace" => "team_shared"
          },
          "eng_bob" => {
            "id" => "eng_bob",
            "name" => "Bob Eng",
            "role" => "engineer",
            "github_username" => "@bobbuilder",
            "memory_namespace" => "eng_bob_private"
          },
          "view_cara" => {
            "id" => "view_cara",
            "name" => "Cara Viewer",
            "role" => "viewer",
            "memory_namespace" => "readonly"
          }
        },
        "roles" => {
          "pm" => %w[edit_workflow manage_skills configure_memory publish read_workflow inspect_run],
          "engineer" => %w[run_workflow approve_gates read_workflow inspect_run],
          "viewer" => %w[read_workflow inspect_run]
        },
        "sqlite_path" => File.join(db_dir, "riggs.sqlite3"),
        "sqlite_memory" => {
          "vector_path" => ENV["RIGGS_VECTOR_EXT"],
          "memory_path" => ENV["RIGGS_MEMORY_EXT"],
          "embed_model" => ENV["RIGGS_EMBED_MODEL"]
        },
        "providers" => {
          "mock" => { "type" => "mock" },
          "claude" => { "type" => "anthropic" },
          "openai" => { "type" => "openai" },
          "ollama" => { "type" => "ollama", "base_url" => "http://127.0.0.1:11434/v1", "model" => "llama3" },
          "cursor" => { "type" => "cursor" },
          "claude_cli" => { "type" => "claude_cli" },
          "codex" => { "type" => "codex" },
          "cursor_cloud" => {
            "type" => "cursor_cloud",
            "model" => "composer-2.5",
            "repos" => [],
            "poll_interval_seconds" => 5
          }
        },
        "mcp_servers" => {}
      }

      config_file = File.expand_path(".agent_hubrc", base_dir)
      File.write(config_file, Psych.dump(hub_cfg))
      puts "✅ Created #{config_file}"

      # Copy example playbook + skill into the project if missing
      example_src = File.expand_path("../../../config/riggs/workflows/example_triage.yml", __dir__)
      example_dst = File.join(workflows_dir, "example_triage.yml")
      if File.exist?(example_src) && !File.exist?(example_dst)
        FileUtils.cp(example_src, example_dst)
        puts "✅ Installed example playbook → #{example_dst}"
      end

      skill_src = File.expand_path("../../../config/riggs/skills/triage_v1/SKILL.yml", __dir__)
      skill_dst_dir = File.join(skills_dir, "triage_v1")
      if File.exist?(skill_src)
        FileUtils.mkdir_p(skill_dst_dir)
        FileUtils.cp(skill_src, File.join(skill_dst_dir, "SKILL.yml")) unless File.exist?(File.join(skill_dst_dir, "SKILL.yml"))
      end

      db_path = File.join(db_dir, "riggs.sqlite3")
      Storage.new(db_path: db_path).close
      puts "✅ Database ready at #{db_path}"
      puts "\n🎉 Riggs setup complete!"
    end

    desc "identity:show", "Show current user, role, GitHub handle, and memory scope."
    def identity_show
      identity = current_identity
      print_header("Current Identity")
      puts "👤 ID: #{identity[:id]}"
      puts "🏷️  Role: #{identity[:role].to_s.upcase}"
      puts "🔗 GitHub: #{identity[:github_username] || 'Not linked'}"
      puts "🧠 Memory Scope: #{identity[:memory_namespace]}"
      puts "🔑 Permissions: #{identity[:permissions].join(', ')}"
    end

    desc "workflow:new NAME", "Create a new workflow YAML from a template."
    def workflow_new(name)
      require_permission! %w[edit_workflow]
      path = "./config/riggs/workflows/#{name}.yml"
      FileUtils.mkdir_p(File.dirname(path))
      if File.exist?(path)
        abort "❌ Already exists: #{path}"
      end

      File.write(path, <<~YAML)
        name: #{name}
        display_name: #{name.tr('_', ' ').split.map(&:capitalize).join(' ')}
        triggers:
          - type: manual
        context_window: medium
        max_llm_calls: 20
        timeout_seconds: 300
        memory_scope:
          isolation: namespaced
        providers:
          default:
            relay_chain: [mock]
        steps:
          - id: start
            label: Start
            agent: default
            input: "Begin playbook for {{workflow.input.topic}}"
            output_var: start_result
            next: finish
          - id: finish
            label: Finish
            agent: default
            input: "Summarize: {{workflow.start.start_result}}"
            output_var: final_summary
      YAML
      puts "✅ Created #{path}"
    end

    desc "workflow:validate NAME", "Validate the DAG for cycles and missing references."
    def workflow_validate(name)
      require_permission! %w[edit_workflow read_workflow]
      workflow = load_workflow(name)
      report = Workflow::Loader.validate(workflow)

      print_header("Validation Report")
      if report[:valid]
        puts "✅ DAG is valid. No cycles or undefined references."
        puts "📐 Steps: #{report[:step_count]}"
        puts "🔁 Max depth: #{report[:max_depth]}"
      else
        report[:errors].each { |e| puts "❌ #{e}" }
        exit 1
      end
    end

    desc "workflow:simulate NAME", "Dry-run with mock outputs, print trace + Mermaid export."
    def workflow_simulate(name)
      require_permission! %w[read_workflow run_workflow edit_workflow]
      workflow = load_workflow(name)
      print_header("Simulation Trace (Mock LLM)")

      input = { ticket: "Sample ticket about login ERROR" }
      outputs = {}
      steps_by_id = workflow[:steps].each_with_object({}) { |s, h| h[s.id] = s }
      current = workflow[:steps].first
      visited = []

      while current && visited.size < workflow[:steps].size + 2
        visited << current.id
        gates = current.gates.empty? ? "none" : current.gates.join(", ")
        puts "\n✅ Step: #{current.label} (#{current.id})"
        puts "   Agent: #{current.agent} | Gates: #{gates}"

        template_ctx = { input: input }
        workflow[:steps].each do |s|
          next unless outputs[s.output_var]

          template_ctx[s.id.to_sym] = { s.output_var.to_sym => outputs[s.output_var] }
        end
        input_preview = Workflow::Loader.resolve_context(current.input, template_ctx)
        puts "   Input Preview: #{input_preview[0, 80]}..."
        mock = input_preview.match?(/ERROR/i) ? "classification=ERROR" : "classification=OK"
        outputs[current.output_var] = mock
        puts "   Mock Output: #{mock}"
        next_id = Workflow::Loader.resolve_next(current, outputs: outputs, gate_decision: :approved)
        puts "   Next: #{next_id || '(end)'}"
        current = next_id ? steps_by_id[next_id] : nil
      end

      puts "\n📤 Mermaid export:"
      puts "flowchart TD"
      workflow[:steps].each do |s|
        Workflow::Loader.resolve_next_targets(s.next).each do |t|
          puts "  #{s.id}[#{s.id}] --> #{t}[#{t}]"
        end
      end
    end

    desc "workflow:run NAME", "Execute the workflow DAG with gates/memory/providers."
    method_option :input, type: :hash, default: {}, desc: "Workflow input key=value pairs"
    method_option :ticket, type: :string, desc: "Shorthand for input ticket text"
    method_option :auto_approve, type: :boolean, default: false, desc: "Auto-approve HITL gates (CI)"
    def workflow_run(name)
      require_permission! %w[run_workflow]
      workflow = load_workflow(name)
      identity = current_identity
      cfg = load_config

      print_header("Running Workflow: #{workflow[:display_name] || name}")
      puts "👤 User: #{identity[:id]} (#{identity[:role]})"
      puts "🧠 Memory Scope: #{identity[:memory_namespace]}"
      puts "⏱️  Max Calls: #{workflow[:max_llm_calls]}"

      input = (options[:input] || {}).transform_keys(&:to_sym)
      input[:ticket] = options[:ticket] if options[:ticket]

      gate_handler = if options[:auto_approve]
                       ->(step, io) {
                         io.puts "⏸ Auto-approving gate on '#{step.id}'"
                         :approved
                       }
                     end

      skill_registry = SkillRegistry.new
      mcp = begin
        MCP::Client.from_config(cfg[:mcp_servers])
      rescue StandardError
        nil
      end

      engine = Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: cfg[:sqlite_path] || "./db/riggs.sqlite3",
        hub_config: cfg,
        gate_handler: gate_handler,
        skill_registry: skill_registry,
        mcp_client: mcp
      )
      engine.execute($stdout, input: input)

      FileUtils.mkdir_p("./db/audit")
      File.write(
        "./db/audit/#{workflow[:name]}_#{Time.now.to_i}.json",
        JSON.pretty_generate(engine.audit_log)
      )
      puts "📁 Audit log saved to ./db/audit/ (also in riggs_audit table)"
    end

    desc "workflow:inspect SESSION_ID", "Show session status and audit events (viewer+)."
    def workflow_inspect(session_id)
      require_permission! %w[inspect_run read_workflow]
      cfg = load_config
      storage = Storage.new(db_path: cfg[:sqlite_path] || "./db/riggs.sqlite3")
      session = storage.find_session(session_id)
      abort "❌ Session not found" unless session

      print_header("Session #{session_id}")
      puts "Workflow: #{session['workflow_name']}"
      puts "User: #{session['user_id']}"
      puts "Status: #{session['status']}"
      puts "\nAudit:"
      storage.list_audit(session_id).each do |row|
        puts "  [#{row['created_at']}] #{row['event_type']} #{row['payload']}"
      end
      storage.close
    end

    desc "memory:recall QUERY", "Search long-term memory for current user."
    def memory_recall(query)
      identity = current_identity
      cfg = load_config
      db_path = cfg[:sqlite_path] || "./db/riggs.sqlite3"

      print_header("Memory Recall")
      puts "🔍 Query: #{query}"
      puts "🧠 Scope: #{identity[:memory_namespace]}"

      memory = MemoryService.new(
        namespace: identity[:memory_namespace],
        db_path: db_path,
        config: cfg[:sqlite_memory] || {}
      )
      results = memory.recall(query)
      memory.close
      if results.empty?
        puts "📭 No relevant memories found."
      else
        Array(results).each_with_index { |r, i| puts "\n#{i + 1}. #{r}" }
      end
    end

    desc "memory:persist TEXT", "Persist a memory snippet for the current user namespace."
    method_option :context, type: :string, default: "manual"
    def memory_persist(text)
      require_permission! %w[configure_memory run_workflow]
      identity = current_identity
      cfg = load_config
      memory = MemoryService.new(
        namespace: identity[:memory_namespace],
        db_path: cfg[:sqlite_path] || "./db/riggs.sqlite3",
        config: cfg[:sqlite_memory] || {}
      )
      memory.persist(text, context: options[:context])
      memory.close
      puts "✅ Persisted to namespace #{identity[:memory_namespace]} (backend may be FTS fallback)"
    end

    desc "skills:list", "List installed skill bundles."
    def skills_list
      require_permission! %w[manage_skills read_workflow]
      registry = SkillRegistry.new
      list = registry.list
      puts list.empty? ? "No skills found in config/riggs/skills" : list.map { |s| "• #{s}" }.join("\n")
    end

    desc "providers:ping NAME", "One-shot complete() against a named provider (smoke test)."
    method_option :prompt, type: :string, default: "Reply with the single word: pong"
    def providers_ping(name)
      require_permission! %w[run_workflow configure_memory]
      cfg = load_config
      router = Providers::Router.new(hub_providers: cfg[:providers] || {})
      print_header("Provider Ping: #{name}")
      begin
        result = router.call(
          chain: [name],
          messages: [{ role: "user", content: options[:prompt] }],
          timeout: 120
        )
        puts "✅ provider=#{result[:provider]} relay_attempt=#{result[:relay_attempt]}"
        puts result[:content].to_s[0, 500]
      rescue Providers::Error => e
        abort "❌ #{e.class}: #{e.message}"
      end
    end

    no_commands do
      def config_path
        Identity.config_path
      end

      def load_config
        Identity.load_config
      end

      def current_identity
        @current_identity ||= Identity.resolve(cli_user: options[:user])
      end

      # Pass an array to require ANY of the listed permissions; use require_all_permissions! for ALL.
      def require_permission!(permissions)
        identity = current_identity
        needed = Array(permissions).map(&:to_s)
        return if needed.any? { |p| identity[:permissions].include?(p) }

        abort "⛔ Access denied. '#{identity[:role]}' lacks required permission(s): #{needed.join(' or ')}"
      end

      def load_workflow(name)
        path = "./config/riggs/workflows/#{name}.yml"
        # Also try gem-bundled examples
        unless File.exist?(path)
          path = File.expand_path("../../../config/riggs/workflows/#{name}.yml", __dir__)
        end
        abort "❌ Workflow not found: #{name}.yml" unless File.exist?(path)

        Workflow::Loader.load(path: path)
      end

      def print_header(title)
        puts "\n== #{title.upcase} =="
        puts "─" * 40
      end
    end
  end
end

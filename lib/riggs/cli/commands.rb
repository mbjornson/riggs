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
require_relative "../mcp/manager"
require_relative "../providers/router"
require_relative "../triggers"

module Riggs
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    class_option :user, type: :string, desc: "Override default user from .agent_hubrc"

    map "identity:show" => :identity_show
    map "config:show" => :config_show
    map "workflow:new" => :workflow_new
    map "workflow:validate" => :workflow_validate
    map "workflow:simulate" => :workflow_simulate
    map "workflow:run" => :workflow_run
    map "workflow:resume" => :workflow_resume
    map "workflow:inspect" => :workflow_inspect
    map "memory:recall" => :memory_recall
    map "memory:persist" => :memory_persist
    map "skills:list" => :skills_list
    map "skills:show" => :skills_show
    map "providers:ping" => :providers_ping
    map "mcp:list" => :mcp_list
    map "mcp:ping" => :mcp_ping
    map "triggers:match" => :triggers_match
    map "triggers:list" => :triggers_list

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
          "engineer" => %w[run_workflow approve_gates read_workflow inspect_run manage_mcp],
          "viewer" => %w[read_workflow inspect_run]
        },
        "sqlite_path" => File.join(db_dir, "riggs.sqlite3"),
        "sqlite_memory" => {
          "vector_path" => ENV.fetch("RIGGS_VECTOR_EXT", nil),
          "memory_path" => ENV.fetch("RIGGS_MEMORY_EXT", nil),
          "embed_model" => ENV.fetch("RIGGS_EMBED_MODEL", nil)
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
      if File.exist?(config_file)
        puts "⏭️  Keeping existing #{config_file} (delete it and re-run setup to regenerate)"
      else
        File.write(config_file, Psych.dump(hub_cfg))
        puts "✅ Created #{config_file}"
      end

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

    desc "config:show", "Show .agent_hubrc with secrets masked."
    def config_show
      require_permission! %w[read_workflow edit_workflow configure_memory]
      store = ConfigStore.new
      print_header("Config (#{store.path})")
      puts Psych.dump(store.public_view)
    end

    desc "serve", "Start the Riggs web UI / JSON API (Rack) against the current project."
    method_option :port, type: :numeric, default: 4567, aliases: "-p"
    method_option :bind, type: :string, default: "127.0.0.1", aliases: "-b"
    def serve
      require "rack"
      require "rackup"
      require_relative "../web/app"

      abort "❌ Missing .agent_hubrc in #{Dir.pwd}. Run 'riggs setup' first." unless Identity.config_path

      port = options[:port]
      bind = options[:bind]
      puts "🌐 Riggs web UI on http://#{bind}:#{port} (cwd=#{Dir.pwd})"
      puts "   Auth: cookie user picker, X-Riggs-User header, or ?user="
      Rackup::Server.start(
        app: Riggs::Web::App,
        Host: bind,
        Port: port
      )
    end

    desc "triggers:match TEXT", "List playbooks whose keyword triggers match TEXT."
    def triggers_match(text)
      require_permission! %w[read_workflow]
      matches = Triggers.find_workflows(text: text)
      print_header("Trigger Match")
      if matches.empty?
        puts "No playbooks matched #{text.inspect}."
      else
        matches.each do |wf|
          puts "• #{wf[:name]} — #{wf[:display_name] || wf[:name]}"
        end
      end
    end

    desc "triggers:list", "Show declared triggers for each playbook."
    def triggers_list
      require_permission! %w[read_workflow]
      rows = Triggers.list_declared
      print_header("Playbook Triggers")
      if rows.empty?
        puts "No playbooks found in config/riggs/workflows/."
        return
      end
      rows.each do |row|
        summary = row[:triggers].map do |t|
          if t[:type] == "keyword"
            "keyword(#{Array(t[:keywords]).join(', ')})"
          else
            t[:type]
          end
        end.join(", ")
        summary = "(none)" if summary.empty?
        puts "• #{row[:name]} — #{summary}"
      end
    end

    desc "workflow:new NAME", "Create a new workflow YAML (interactive composer, or --non-interactive)."
    method_option :non_interactive, type: :boolean, default: false, aliases: "-n",
                                    desc: "Skip prompts; write a default 2-step template"
    method_option :display_name, type: :string, desc: "Display name"
    method_option :trigger, type: :string, default: "manual", enum: %w[manual keyword],
                            desc: "Trigger type for non-interactive / default"
    method_option :keywords, type: :string, desc: "Comma-separated keywords when trigger=keyword"
    method_option :steps, type: :numeric, default: 2, desc: "Step count for non-interactive template (min 2)"
    method_option :relay_chain, type: :string, default: "mock", desc: "Comma-separated relay_chain"
    method_option :validate, type: :boolean, default: true, desc: "Validate after write"
    def workflow_new(name)
      require_permission! %w[edit_workflow]
      path = "./config/riggs/workflows/#{name}.yml"
      FileUtils.mkdir_p(File.dirname(path))
      abort "❌ Already exists: #{path}" if File.exist?(path)

      spec =
        if options[:non_interactive] || !$stdin.tty?
          compose_non_interactive(name)
        else
          compose_interactive(name)
        end

      File.write(path, Psych.dump(spec))
      puts "✅ Created #{path}"

      return unless options[:validate]

      report = Workflow::Loader.validate(Workflow::Loader.load(path: path))
      if report[:valid]
        puts "✅ Valid (#{report[:step_count]} steps)"
      else
        puts "⚠️  Validation issues: #{report[:errors].join('; ')}"
      end
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
      steps_by_id = workflow[:steps].to_h { |s| [s.id, s] }
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
                       lambda { |step, io|
                         io.puts "⏸ Auto-approving gate on '#{step.id}'"
                         :approved
                       }
                     end

      skill_registry = SkillRegistry.new
      mcp_manager = begin
        MCP::Manager.from_config(cfg[:mcp_servers])
      rescue StandardError => e
        warn "⚠️  MCP disabled for this run — mcp_servers config error: #{e.message}"
        nil
      end

      engine = Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: cfg[:sqlite_path] || "./db/riggs.sqlite3",
        hub_config: cfg,
        gate_handler: gate_handler,
        skill_registry: skill_registry,
        mcp_manager: mcp_manager
      )
      engine.execute($stdout, input: input)

      FileUtils.mkdir_p("./db/audit")
      File.write(
        "./db/audit/#{workflow[:name]}_#{Time.now.to_i}.json",
        JSON.pretty_generate(engine.audit_log)
      )
      puts "📁 Audit log saved to ./db/audit/ (also in riggs_audit table)"
    end

    desc "workflow:resume SESSION_ID", "Resume a workflow session paused at a HITL gate."
    def workflow_resume(session_id)
      require_permission! %w[run_workflow]
      cfg = load_config
      db_path = cfg[:sqlite_path] || "./db/riggs.sqlite3"

      storage = Storage.new(db_path: db_path)
      session = storage.find_session(session_id)
      storage.close
      abort "❌ Session not found: #{session_id}" unless session

      workflow = load_workflow(session["workflow_name"])
      identity = current_identity

      print_header("Resuming Workflow: #{workflow[:display_name] || session['workflow_name']}")
      puts "👤 User: #{identity[:id]} (#{identity[:role]})"
      puts "🧠 Memory Scope: #{identity[:memory_namespace]}"
      puts "🔁 Session: #{session_id} (status=#{session['status']})"

      mcp_manager = begin
        MCP::Manager.from_config(cfg[:mcp_servers])
      rescue StandardError => e
        warn "⚠️  MCP disabled for this run — mcp_servers config error: #{e.message}"
        nil
      end

      begin
        Workflow::GraphEngine.resume(
          session_id: session_id,
          user_identity: identity,
          workflow: workflow,
          db_path: db_path,
          hub_config: cfg,
          skill_registry: SkillRegistry.new,
          mcp_manager: mcp_manager,
          io: $stdout
        )
      rescue WorkflowError => e
        abort "❌ Cannot resume #{session_id}: #{e.message}"
      end
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
      usage = storage.session_usage(session_id)
      puts "Tokens: #{format_usage(usage)}"
      storage.step_usage(session_id).each do |row|
        puts "  #{row[:step_key]}: #{format_usage(row)}"
      end
      puts "\nAudit:"
      storage.list_audit(session_id).each do |row|
        puts "  [#{row['created_at']}] #{row['event_type']} #{row['payload']}"
      end
      storage.close
    end

    desc "memory:recall QUERY", "Search long-term memory for current user."
    def memory_recall(query)
      require_permission! %w[configure_memory run_workflow]
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
      if list.empty?
        puts "No skills found in config/riggs/skills"
      else
        list.each { |s| puts "• #{s[:name]} (latest #{s[:latest]}; versions: #{s[:versions].join(', ')})" }
      end
    end

    desc "skills:show NAME", "Show skill system prompt, version, and tools (NAME or NAME@ver)."
    def skills_show(name)
      require_permission! %w[manage_skills read_workflow]
      skill = SkillRegistry.new.load(name)
      abort "❌ Skill not found: #{name}" unless skill

      print_header("Skill #{skill[:name]}@#{skill[:version]}")
      puts skill[:system_prompt]
      puts "\nMCP servers: #{skill[:mcp_servers].empty? ? '(none)' : skill[:mcp_servers].join(', ')}"
      puts "Tools:"
      if skill[:tools].empty?
        puts "  (none)"
      else
        skill[:tools].each do |t|
          mcp = t[:mcp_server] ? " [mcp:#{t[:mcp_server]}]" : ""
          puts "  • #{t[:name]}#{mcp} — #{t[:description]}"
        end
      end
    end

    desc "mcp:list", "List configured MCP servers and their tools."
    def mcp_list
      require_permission! %w[manage_mcp run_workflow]
      cfg = load_config
      mgr = MCP::Manager.from_config(cfg[:mcp_servers])
      if mgr.server_names.empty?
        puts "No mcp_servers configured in .agent_hubrc"
        return
      end
      print_header("MCP Servers")
      mgr.server_names.each do |s|
        puts "• #{s}"
        mgr.list_tools(servers: [s]).each do |t|
          puts "    - #{t[:name]}: #{t[:description][0, 80]}"
        end
      end
      mgr.close
    end

    desc "mcp:ping [SERVER]", "Ping MCP server(s) and report tool counts."
    def mcp_ping(server = nil)
      require_permission! %w[manage_mcp run_workflow]
      cfg = load_config
      mgr = MCP::Manager.from_config(cfg[:mcp_servers])
      abort "No mcp_servers configured" if mgr.server_names.empty?

      print_header("MCP Ping")
      mgr.ping(server).each do |r|
        if r[:ok]
          puts "✅ #{r[:server]} — #{r[:tool_count]} tools"
        else
          puts "❌ #{r[:server]} — #{r[:error]}"
        end
      end
      mgr.close
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
        puts "   usage=#{result[:usage][:measured] ? result[:usage][:total_tokens].to_s : 'unmeasured'} " \
             "cost=#{result[:cost_usd] ? format('$%.6f', result[:cost_usd]) : 'unpriced'}"
        puts result[:content].to_s[0, 500]
      rescue Providers::Error => e
        abort "❌ #{e.class}: #{e.message}"
      end
    end

    no_commands do
      # Never prints a total without its coverage — a bare number would imply
      # complete measurement that CLI providers cannot supply.
      def format_usage(u)
        return "no provider calls" if u[:calls].zero?

        tokens = u[:total_tokens] ? "#{u[:total_tokens]} tokens" : "unmeasured"
        cost =
          if u[:cost_usd]
            format("$%<cost>.4f over %<priced>d of %<calls>d priced",
                   cost: u[:cost_usd], priced: u[:priced_calls], calls: u[:calls])
          else
            "unpriced"
          end
        "#{tokens} over #{u[:measured_calls]} of #{u[:calls]} calls · #{cost}"
      end

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
        return if needed.intersect?(identity[:permissions])

        abort "⛔ Access denied. '#{identity[:role]}' lacks required permission(s): #{needed.join(' or ')}"
      end

      def load_workflow(name)
        path = "./config/riggs/workflows/#{name}.yml"
        # Also try gem-bundled examples
        path = File.expand_path("../../../config/riggs/workflows/#{name}.yml", __dir__) unless File.exist?(path)
        abort "❌ Workflow not found: #{name}.yml" unless File.exist?(path)

        Workflow::Loader.load(path: path)
      end

      def print_header(title)
        puts "\n== #{title.upcase} =="
        puts "─" * 40
      end

      def compose_non_interactive(name)
        display = options[:display_name].to_s
        display = name.tr("_", " ").split.map(&:capitalize).join(" ") if display.empty?
        trigger = options[:trigger].to_s
        triggers =
          if trigger == "keyword"
            kws = options[:keywords].to_s.split(",").map(&:strip).reject(&:empty?)
            kws = [name] if kws.empty?
            [{ "type" => "keyword", "keywords" => kws }]
          else
            [{ "type" => "manual" }]
          end
        chain = options[:relay_chain].to_s.split(",").map(&:strip).reject(&:empty?)
        chain = ["mock"] if chain.empty?
        n = [options[:steps].to_i, 2].max
        steps = n.times.map do |i|
          id =
            if i.zero?
              "start"
            elsif i == n - 1
              "finish"
            else
              "step_#{i + 1}"
            end
          {
            "id" => id,
            "label" => id.tr("_", " ").split.map(&:capitalize).join(" "),
            "agent" => "default",
            "input" => (i.zero? ? "Begin playbook for {{workflow.input.topic}}" : "Continue from prior step"),
            "output_var" => "#{id}_result"
          }
        end
        steps.each_with_index do |step, i|
          step["next"] = steps[i + 1]["id"] if i < steps.length - 1
        end
        if steps.length >= 2
          prev = steps[-2]
          steps.last["input"] = "Summarize: {{workflow.#{prev['id']}.#{prev['output_var']}}}"
        end

        {
          "name" => name,
          "display_name" => display,
          "triggers" => triggers,
          "context_window" => "medium",
          "max_llm_calls" => 20,
          "timeout_seconds" => 300,
          "memory_scope" => { "isolation" => "namespaced" },
          "providers" => { "default" => { "relay_chain" => chain } },
          "steps" => steps
        }
      end

      def compose_interactive(name)
        print_header("Compose Playbook: #{name}")
        display = ask("Display name", default: name.tr("_", " ").split.map(&:capitalize).join(" "))
        trigger = ask("Trigger type (manual/keyword)", default: options[:trigger] || "manual")
        triggers =
          if trigger.to_s.downcase.start_with?("key")
            raw = ask("Keywords (comma-separated)", default: name)
            kws = raw.split(",").map(&:strip).reject(&:empty?)
            [{ "type" => "keyword", "keywords" => kws }]
          else
            [{ "type" => "manual" }]
          end
        chain_raw = ask("relay_chain (comma-separated)", default: options[:relay_chain] || "mock")
        chain = chain_raw.split(",").map(&:strip).reject(&:empty?)
        chain = ["mock"] if chain.empty?

        count = ask("Number of steps", default: "2").to_i
        count = 2 if count < 2
        steps = []
        count.times do |i|
          puts "\n— Step #{i + 1} of #{count} —"
          default_id = if i.zero?
                         "start"
                       else
                         (i == count - 1 ? "finish" : "step_#{i + 1}")
                       end
          id = ask("id", default: default_id)
          label = ask("label", default: id.tr("_", " ").split.map(&:capitalize).join(" "))
          agent = ask("agent label", default: "default")
          skill = ask("skill (optional)", default: "")
          input = ask("input", default: (i.zero? ? "Begin for {{workflow.input.topic}}" : "Continue from prior step"))
          gate = ask("gates (none/approval)", default: "none")
          step = {
            "id" => id,
            "label" => label,
            "agent" => agent,
            "input" => input,
            "output_var" => "#{id}_result"
          }
          step["skill"] = skill unless skill.strip.empty?
          step["gates"] = ["approval"] if gate.to_s.downcase.include?("approv")
          steps << step
        end
        steps.each_with_index do |step, i|
          if i < steps.length - 1
            hint = ask("next for #{step['id']} (default: #{steps[i + 1]['id']})", default: steps[i + 1]["id"])
            step["next"] = hint
          end
        end

        {
          "name" => name,
          "display_name" => display,
          "triggers" => triggers,
          "context_window" => "medium",
          "max_llm_calls" => 20,
          "timeout_seconds" => 300,
          "memory_scope" => { "isolation" => "namespaced" },
          "providers" => { "default" => { "relay_chain" => chain } },
          "steps" => steps
        }
      end
    end
  end
end

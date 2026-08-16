# frozen_string_literal: true

require "rack"
require "rack/request"
require "rack/response"
require "json"
require "erb"
require "cgi/escape"
require "stringio"
require "psych"
require "date"
require "time"
require "uri"

require_relative "../config_store"
require_relative "../identity"
require_relative "../storage"
require_relative "../events"
require_relative "../memory/service"
require_relative "../workflow/loader"
require_relative "../workflow/graph_engine"
require_relative "../skills/registry"
require_relative "../providers/router"
require_relative "../triggers"

module Riggs
  # Optional host hook: ->(request) { "pm_alice" }
  class << self
    attr_accessor :identity_mapper
  end

  module Web
    class Forbidden < StandardError; end

    class Auth
      def self.resolve(request, config: nil)
        cfg = config || Identity.load_config
        mapped = Riggs.identity_mapper&.call(request)
        return Identity.resolve(cli_user: mapped.to_s, config: cfg) unless mapped.nil?

        raise Forbidden, "Web identity requires Riggs.identity_mapper" unless App.insecure_identity

        user =
          request.env["HTTP_X_RIGGS_USER"] ||
          request.cookies["riggs_user"] ||
          request.params["user"] ||
          cfg[:default_user]

        Identity.resolve(cli_user: user.to_s, config: cfg)
      rescue Error
        raise unless App.insecure_identity

        Identity.resolve(cli_user: cfg[:default_user].to_s, config: cfg)
      end

      # ANY of the listed permissions is enough.
      def self.require!(identity, *perms)
        needed = perms.flatten.map(&:to_s)
        return true if needed.intersect?(identity[:permissions])

        raise Forbidden, "Missing permission(s): #{needed.join(' or ')}"
      end
    end

    # Framework-agnostic Rack app (standalone `riggs serve` or mounted via Engine).
    class App
      VIEWS = File.expand_path("views", __dir__)

      # A stream is bounded so a client reconnects with after=<last_id> rather
      # than holding a connection (and a Storage handle) open forever.
      DEFAULT_STREAM_TIMEOUT_SECONDS = 30
      # Rows fetched per stream poll. A full page means more are waiting, so the
      # stream drains again immediately instead of sleeping or signalling done.
      STREAM_PAGE_SIZE = 500
      DEFAULT_STREAM_POLL_SECONDS = 1.0
      YAML_CONFIG_MAX_BYTES = 64 * 1024
      # One permission per top-level key. Auth.require! ORs its arguments, so
      # callers must pass a single permission for an ALL-of / exact check.
      CONFIG_KEY_PERMISSIONS = {
        "users" => "edit_workflow",
        "roles" => "edit_workflow",
        "default_user" => "edit_workflow",
        "providers" => "edit_workflow",
        "mcp_servers" => "manage_mcp",
        "sqlite_memory" => "configure_memory",
        "sqlite_path" => "configure_memory"
      }.freeze
      GATE_DECISION_STATUSES = %w[paused awaiting_approval].freeze
      MUTATING_METHODS = %w[POST PATCH PUT DELETE].freeze

      class << self
        # Overridable so tests do not have to wait out the production cap.
        attr_writer :stream_timeout_seconds, :stream_poll_seconds
        # When false (the default), identity comes only from Riggs.identity_mapper
        # and mutating requests need a matching Origin or Referer host.
        attr_accessor :insecure_identity

        def stream_timeout_seconds
          @stream_timeout_seconds || DEFAULT_STREAM_TIMEOUT_SECONDS
        end

        def stream_poll_seconds
          @stream_poll_seconds || DEFAULT_STREAM_POLL_SECONDS
        end
      end

      self.insecure_identity = false

      def self.call(env)
        new.call(env)
      end

      def initialize(stream_timeout_seconds: nil, stream_poll_seconds: nil)
        @stream_timeout_seconds = (stream_timeout_seconds || self.class.stream_timeout_seconds).to_f
        @stream_poll_seconds = (stream_poll_seconds || self.class.stream_poll_seconds).to_f
      end

      def call(env)
        req = Rack::Request.new(env)
        @script_name = req.script_name.to_s
        @path = normalize_path(req.path_info)

        begin
          reject_cross_site!(req)
          @config = Identity.load_config
          @identity = Auth.resolve(req, config: @config)
          @store = ConfigStore.new(path: Identity.config_path)
          dispatch(req) || respond_error(req, 404, "Not found")
        rescue Forbidden => e
          respond_error(req, 403, e.message)
        rescue Error => e
          respond_error(req, 400, e.message)
        rescue StandardError => e
          respond_error(req, 500, "#{e.class}: #{e.message}")
        end
      end

      private

      def normalize_path(path)
        p = path.to_s
        p = "/" if p.empty?
        p = p.sub(%r{/\z}, "") unless p == "/"
        p
      end

      def reject_cross_site!(req)
        return if self.class.insecure_identity
        return unless MUTATING_METHODS.include?(req.request_method)
        return if origin_matches_host?(req)

        raise Forbidden, "Cross-site request rejected"
      end

      def origin_matches_host?(req)
        expected = req.host.to_s.downcase
        %w[HTTP_ORIGIN HTTP_REFERER].any? do |key|
          raw = req.get_header(key).to_s
          next false if raw.empty?

          URI.parse(raw).host.to_s.downcase == expected
        rescue URI::InvalidURIError
          false
        end
      end

      def dispatch(req)
        m = req.request_method
        p = @path

        return html(:dashboard, title: "Dashboard") if m == "GET" && ["/", "/dashboard"].include?(p)
        return html(:login, title: "Switch user", users: @config[:users] || {}) if m == "GET" && p == "/login"
        return post_login(req) if m == "POST" && p == "/login"

        if m == "GET" && p == "/config"
          Auth.require!(@identity, "edit_workflow", "configure_memory", "manage_skills", "read_workflow")
          return html(:config, title: "Configuration", view: @store.public_view)
        end
        return post_config(req) if m == "POST" && p == "/config"

        if m == "GET" && p == "/workflows"
          Auth.require!(@identity, "read_workflow")
          return html(:workflows, title: "Playbooks", workflows: list_workflows)
        end
        if m == "GET" && (wm = p.match(%r{\A/workflows/([^/]+)\z}))
          return show_workflow(wm[1])
        end
        if m == "POST" && (wm = p.match(%r{\A/workflows/([^/]+)/run\z}))
          return run_workflow_web(req, wm[1])
        end

        if m == "GET" && p == "/sessions"
          Auth.require!(@identity, "inspect_run")
          return html(:sessions, title: "Sessions", sessions: list_sessions)
        end
        if m == "GET" && (sm = p.match(%r{\A/sessions/([^/]+)\z}))
          return show_session(sm[1])
        end
        if m == "POST" && (sm = p.match(%r{\A/sessions/([^/]+)/(approve|reject)\z}))
          return session_decision(sm[1], sm[2] == "approve" ? "approved" : "rejected")
        end

        if m == "GET" && p == "/memory"
          Auth.require!(@identity, "inspect_run", "configure_memory", "read_workflow")
          q = req.params["q"].to_s
          hits = q.empty? ? [] : memory_search(q)
          return html(:memory, title: "Memory", query: q, hits: hits)
        end

        if m == "GET" && p == "/skills"
          Auth.require!(@identity, "read_workflow", "manage_skills")
          return html(:skills, title: "Skills", skills: list_skills)
        end

        if m == "GET" && p == "/triggers"
          Auth.require!(@identity, "read_workflow")
          q = req.params["q"].to_s
          matches = q.empty? ? [] : trigger_matches(q)
          declared = Triggers.list_declared(dir: workflows_dir)
          return html(:triggers, title: "Triggers", query: q, matches: matches, declared: declared)
        end

        # JSON API
        if m == "GET" && p == "/api/config"
          Auth.require!(@identity, "read_workflow", "edit_workflow", "configure_memory")
          return json_ok(@store.public_view)
        end
        return api_patch_config(req) if %w[PATCH POST].include?(m) && p == "/api/config"

        if m == "GET" && p == "/api/workflows"
          Auth.require!(@identity, "read_workflow")
          return json_ok(list_workflows)
        end
        if m == "GET" && (wm = p.match(%r{\A/api/workflows/([^/]+)\z}))
          return api_show_workflow(wm[1])
        end
        if m == "POST" && (wm = p.match(%r{\A/api/workflows/([^/]+)/run\z}))
          return api_run_workflow(req, wm[1])
        end
        if m == "GET" && (sm = p.match(%r{\A/api/sessions/([^/]+)/audit\z}))
          return api_session_audit(sm[1])
        end
        # Registered before the bare /api/sessions/:id route so it cannot be swallowed.
        if m == "GET" && (sm = p.match(%r{\A/api/sessions/([^/]+)/events\z}))
          return api_session_events(req, sm[1])
        end
        if m == "GET" && (sm = p.match(%r{\A/api/sessions/([^/]+)/stream\z}))
          return api_session_stream(req, sm[1])
        end
        # Also registered before the bare /api/sessions/:id route so it cannot be swallowed.
        if m == "GET" && (sm = p.match(%r{\A/api/sessions/([^/]+)/usage\z}))
          return api_session_usage(sm[1])
        end
        if m == "GET" && (sm = p.match(%r{\A/api/sessions/([^/]+)\z}))
          return api_show_session(sm[1])
        end
        if m == "POST" && (sm = p.match(%r{\A/api/sessions/([^/]+)/(approve|reject)\z}))
          return api_session_decision(sm[1], sm[2] == "approve" ? "approved" : "rejected")
        end

        if m == "GET" && p == "/api/memory/search"
          Auth.require!(@identity, "inspect_run", "configure_memory", "read_workflow")
          return json_ok(memory_search(req.params["q"].to_s))
        end
        if m == "GET" && p == "/api/skills"
          Auth.require!(@identity, "read_workflow", "manage_skills")
          return json_ok(list_skills)
        end
        if m == "GET" && p == "/api/mcp/servers"
          Auth.require!(@identity, "manage_mcp", "edit_workflow", "read_workflow")
          return json_ok(mcp_servers_public)
        end
        if m == "GET" && p == "/api/triggers/match"
          Auth.require!(@identity, "read_workflow")
          return json_ok(trigger_matches(req.params["q"].to_s))
        end
        if m == "GET" && p == "/api/triggers"
          Auth.require!(@identity, "read_workflow")
          return json_ok(Triggers.list_declared(dir: workflows_dir))
        end
        return json_ok(ok: true, identity: @identity[:id]) if m == "GET" && p == "/health"

        nil
      end

      def post_login(req)
        user = req.params["user"].to_s
        users = @config[:users] || {}
        raise Error, "Unknown user" unless users.key?(user.to_sym) || users.key?(user)

        res = Rack::Response.new
        res.redirect(url("/"))
        res.set_cookie("riggs_user", value: user, path: cookie_path, httponly: true, same_site: :lax)
        res.finish
      end

      def post_config(req)
        section = req.params["section"].to_s
        case section
        when "users"
          # parse_users_form only writes users / default_user, never roles or MCP.
          Auth.require!(@identity, "edit_workflow")
          @store.merge!(parse_users_form(req))
        when "providers"
          Auth.require!(@identity, "edit_workflow")
          @store.merge!(parse_providers_form(req))
        when "mcp"
          Auth.require!(@identity, "manage_mcp")
          @store.merge!(parse_mcp_form(req))
        when "memory"
          Auth.require!(@identity, "configure_memory")
          @store.merge!(parse_memory_form(req))
        when "yaml"
          parsed = parse_yaml_config_param(req.params["yaml"])
          authorize_config_keys!(parsed.keys)
          @store.merge!(parsed)
        else
          raise Error, "Unknown config section"
        end

        res = Rack::Response.new
        res.redirect(url("/config?saved=1"))
        res.finish
      end

      def show_workflow(name)
        Auth.require!(@identity, "read_workflow")
        path = workflow_path(name)
        raise Error, "Workflow not found" unless path

        wf = Workflow::Loader.load(path: path)
        report = Workflow::Loader.validate(wf)
        html(:workflow_show, title: wf[:display_name] || name, name: name, workflow: wf, report: report)
      end

      def run_workflow_web(req, name)
        Auth.require!(@identity, "run_workflow")
        result = execute_workflow(name, input: form_input(req), auto_approve: truthy?(req.params["auto_approve"]))
        res = Rack::Response.new
        res.redirect(url("/sessions/#{result[:session_id]}"))
        res.finish
      end

      def show_session(id)
        Auth.require!(@identity, "inspect_run", "read_workflow")
        storage = open_storage
        session = storage.find_session(id)
        raise Error, "Session not found" unless session

        audit = storage.list_audit(id)
        steps_usage = storage.step_usage(id)
        storage.close
        html(:session_show, title: "Session", session: session, audit: audit, steps_usage: steps_usage)
      end

      def session_decision(id, decision)
        Auth.require!(@identity, "approve_gates")
        apply_session_decision(id, decision)
        res = Rack::Response.new
        res.redirect(url("/sessions/#{id}"))
        res.finish
      end

      def api_patch_config(req)
        body = parse_json_body(req)
        raise Error, "JSON object required" unless body.is_a?(Hash)

        patch = reject_masked_secrets(body)
        authorize_config_keys!(patch.keys)
        # merge! invalidates project trust; do not call public_view (trusted
        # load_config) here. The merged document is the write we just made.
        merged = @store.merge!(patch)
        json_ok(merged)
      end

      def api_show_workflow(name)
        Auth.require!(@identity, "read_workflow")
        path = workflow_path(name)
        return json_error(404, "not found") unless path

        wf = Workflow::Loader.load(path: path)
        json_ok(
          name: wf[:name],
          display_name: wf[:display_name],
          steps: wf[:steps].map { |s| { id: s.id, label: s.label, gates: s.gates, next: s.next } }
        )
      end

      def api_run_workflow(req, name)
        Auth.require!(@identity, "run_workflow")
        body = parse_json_body(req)
        raw_input = body["input"] || body[:input] || {}
        input = raw_input.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        auto = body.key?("auto_approve") ? truthy?(body["auto_approve"]) : true
        json_ok(execute_workflow(name, input: input, auto_approve: auto))
      end

      def api_show_session(id)
        Auth.require!(@identity, "inspect_run", "read_workflow")
        storage = open_storage
        session = storage.find_session(id)
        storage.close
        return json_error(404, "not found") unless session

        json_ok(session)
      end

      def api_session_audit(id)
        Auth.require!(@identity, "inspect_run")
        storage = open_storage
        rows = storage.list_audit(id)
        storage.close
        json_ok(rows)
      end

      def api_session_usage(id)
        Auth.require!(@identity, "inspect_run")
        sid = Storage.utf8(id)
        storage = open_storage
        data = { session: storage.session_usage(sid), steps: storage.step_usage(sid) }
        storage.close
        json_ok(data)
      end

      # Cursor-paged event poll. `last_id` echoes `after` on an empty page so a
      # client can poll forever without losing its place.
      def api_session_events(req, id)
        Auth.require!(@identity, "inspect_run")
        sid = Storage.utf8(id)
        after = req.params["after"].to_i
        limit = Events.clamp_limit(req.params["limit"])

        storage = open_storage
        begin
          session = storage.find_session(sid)
          return json_error(404, "not found") unless session

          rows = storage.list_audit_after(sid, after, limit: limit)
        ensure
          storage.close
        end

        events = rows.map { |row| Events.normalize(row, session_id: sid) }
        status = session["status"].to_s
        json_ok(
          events: events,
          last_id: events.empty? ? after : events.last[:id],
          status: status,
          done: Events.terminal?(status)
        )
      end

      # Server-sent events tail of the audit log.
      def api_session_stream(req, id)
        Auth.require!(@identity, "inspect_run")
        sid = Storage.utf8(id)

        storage = open_storage
        begin
          return json_error(404, "not found") unless storage.find_session(sid)
        ensure
          storage.close
        end

        headers = {
          "content-type" => "text/event-stream",
          "cache-control" => "no-cache",
          "x-accel-buffering" => "no"
        }
        [200, headers, stream_body(sid, req.params["after"].to_i)]
      end

      # Lazy Rack streaming body: nothing runs until the server calls #each.
      # Every poll opens and closes its own Storage handle inside an ensure, so
      # a client that disconnects mid-stream cannot leak a connection.
      def stream_body(sid, after)
        Enumerator.new do |out|
          cursor = after
          deadline = monotonic + @stream_timeout_seconds
          loop do
            status, rows = poll_events(sid, cursor, limit: STREAM_PAGE_SIZE)
            rows.each do |row|
              event = Events.normalize(row, session_id: sid)
              cursor = event[:id]
              out << "id: #{event[:id]}\ndata: #{JSON.generate(event)}\n\n"
            end

            # A full page means more rows are already waiting. Keep draining
            # without sleeping, and never signal done mid-backlog — a client
            # that sees done stops reading and would lose the remainder.
            next if rows.length >= STREAM_PAGE_SIZE

            if Events.terminal?(status)
              out << "event: done\ndata: #{JSON.generate(status: status)}\n\n"
              break
            end
            remaining = deadline - monotonic
            break if remaining <= 0

            sleep([@stream_poll_seconds, remaining].min)
          end
        end
      end

      def poll_events(sid, cursor, limit: STREAM_PAGE_SIZE)
        storage = open_storage
        begin
          session = storage.find_session(sid)
          [session ? session["status"].to_s : "", storage.list_audit_after(sid, cursor, limit: limit)]
        ensure
          storage.close
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def api_session_decision(id, decision)
        Auth.require!(@identity, "approve_gates")
        status = apply_session_decision(id, decision)
        json_ok(ok: true, decision: decision, status: status)
      end

      def execute_workflow(name, input:, auto_approve:)
        path = workflow_path(name)
        raise Error, "Workflow not found: #{name}" unless path

        workflow = Workflow::Loader.load(path: path)
        gate_handler = if auto_approve
                         ->(_step, _io) { :approved }
                       else
                         ->(_step, _io) { :paused }
                       end

        engine = Workflow::GraphEngine.new(
          workflow: workflow,
          user_identity: @identity,
          db_path: sqlite_path,
          hub_config: @config,
          gate_handler: gate_handler,
          skill_registry: SkillRegistry.new
        )
        io = StringIO.new
        engine.execute(io, input: input)
        {
          session_id: engine.session_id,
          status: engine.status.to_s,
          outputs: engine.outputs,
          log: io.string,
          auto_approve: auto_approve
        }
      end

      # Returns the session status after the decision is applied. Approving a
      # run that paused with durable resume state now finishes it in-process;
      # approving anything else only records the decision, as before.
      def apply_session_decision(id, decision)
        storage = open_storage
        workflow_name = nil
        begin
          session = storage.find_session(id)
          raise Error, "Session not found" unless session

          status = session["status"].to_s
          unless GATE_DECISION_STATUSES.include?(status)
            raise Error, "Session is not waiting for a gate decision (status=#{status})"
          end

          storage.audit(
            session_id: id,
            event_type: "gate_decision",
            payload: { decision: decision, via: "web", user: @identity[:id] }
          )
          if decision == "rejected"
            storage.update_session(id, status: "rejected", ended: true)
            return "rejected"
          end

          unless status == "paused" && storage.load_resume_state(id)
            storage.update_session(id, status: "approved_pending_resume")
            return "approved_pending_resume"
          end

          workflow_name = session["workflow_name"]
        ensure
          storage.close
        end

        resume_session_run(id, workflow_name)
      end

      def resume_session_run(id, workflow_name)
        path = workflow_path(workflow_name)
        raise Error, "Workflow not found: #{workflow_name}" unless path

        engine = Workflow::GraphEngine.resume(
          session_id: id,
          user_identity: @identity,
          workflow: Workflow::Loader.load(path: path),
          db_path: sqlite_path,
          hub_config: @config,
          # The paused gate was already approved. Later gates in this resume
          # auto-approve so the operator is not re-prompted in-process.
          gate_handler: ->(_step, _io) { :approved },
          skill_registry: SkillRegistry.new,
          io: StringIO.new
        )
        engine.status.to_s
      end

      def list_workflows
        dirs = [
          File.expand_path("config/riggs/workflows"),
          File.expand_path("../../../config/riggs/workflows", __dir__)
        ]
        dirs.flat_map { |d| Dir.glob(File.join(d, "*.yml")).map { |p| File.basename(p, ".yml") } }.uniq.sort
      end

      def workflows_dir
        local = File.expand_path("config/riggs/workflows")
        return local if File.directory?(local)

        File.expand_path("../../../config/riggs/workflows", __dir__)
      end

      def trigger_matches(query)
        Triggers.find_workflows(text: query, dir: workflows_dir).map do |wf|
          { "name" => wf[:name], "display_name" => wf[:display_name] }
        end
      end

      def workflow_path(name)
        [
          File.expand_path("config/riggs/workflows/#{name}.yml"),
          File.expand_path("../../../config/riggs/workflows/#{name}.yml", __dir__)
        ].find { |p| File.exist?(p) }
      end

      def list_skills
        SkillRegistry.new.list
      rescue StandardError
        []
      end

      def list_sessions
        storage = open_storage
        rows = storage.db.execute(
          "SELECT id, workflow_name, user_id, status, started_at, ended_at FROM riggs_sessions ORDER BY started_at DESC LIMIT 50"
        )
        storage.close
        rows
      end

      def memory_search(query)
        return [] if query.strip.empty?

        svc = MemoryService.new(
          namespace: @identity[:memory_namespace],
          db_path: sqlite_path,
          config: @config[:sqlite_memory] || {}
        )
        hits = svc.recall(query)
        svc.close
        hits
      end

      def mcp_servers_public
        servers = @config[:mcp_servers] || {}
        servers.each_with_object({}) do |(name, cfg), h|
          h[name.to_s] = {
            "command" => cfg[:command] || cfg["command"],
            "args" => cfg[:args] || cfg["args"] || [],
            "env_keys" => (cfg[:env] || cfg["env"] || {}).keys.map(&:to_s)
          }
        end
      end

      def open_storage
        Storage.new(db_path: sqlite_path)
      end

      def sqlite_path
        (@config[:sqlite_path] || "./db/riggs.sqlite3").to_s
      end

      def parse_users_form(req)
        users = {}
        Array(req.params["user_key"]).each_with_index do |key, i|
          next if key.to_s.strip.empty?

          users[key.to_s] = {
            "id" => Array(req.params["user_id"])[i].to_s,
            "name" => Array(req.params["user_name"])[i].to_s,
            "role" => Array(req.params["user_role"])[i].to_s,
            "memory_namespace" => Array(req.params["user_ns"])[i].to_s
          }
        end
        default_user = req.params["default_user"].to_s
        patch = { "users" => users }
        patch["default_user"] = default_user unless default_user.empty?
        patch
      end

      def parse_providers_form(req)
        providers = {}
        Array(req.params["prov_name"]).each_with_index do |name, i|
          next if name.to_s.strip.empty?

          entry = { "type" => Array(req.params["prov_type"])[i].to_s }
          model = Array(req.params["prov_model"])[i].to_s
          entry["model"] = model unless model.empty?
          base = Array(req.params["prov_base"])[i].to_s
          entry["base_url"] = base unless base.empty?
          providers[name.to_s] = entry
        end
        { "providers" => providers }
      end

      def parse_mcp_form(req)
        servers = {}
        Array(req.params["mcp_name"]).each_with_index do |name, i|
          next if name.to_s.strip.empty?

          args = Array(req.params["mcp_args"])[i].to_s.split(/\s+/).reject(&:empty?)
          servers[name.to_s] = {
            "command" => Array(req.params["mcp_command"])[i].to_s,
            "args" => args,
            "env" => {}
          }
        end
        { "mcp_servers" => servers }
      end

      def parse_memory_form(req)
        {
          "sqlite_path" => req.params["sqlite_path"].to_s,
          "sqlite_memory" => {
            "vector_path" => blank_to_nil(req.params["vector_path"]),
            "memory_path" => blank_to_nil(req.params["memory_path"]),
            "embed_model" => blank_to_nil(req.params["embed_model"])
          }
        }
      end

      def blank_to_nil(v)
        s = v.to_s.strip
        s.empty? ? nil : s
      end

      def form_input(req)
        ticket = req.params["ticket"].to_s
        ticket.empty? ? {} : { ticket: ticket }
      end

      def truthy?(v)
        %w[1 true yes on].include?(v.to_s.downcase)
      end

      def parse_json_body(req)
        raw = req.body.read
        req.body.rewind if req.body.respond_to?(:rewind)
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        raise Error, "Invalid JSON body"
      end

      def parse_yaml_config_param(raw)
        text = raw.to_s
        raise Error, "YAML config exceeds 64KB" if text.bytesize > YAML_CONFIG_MAX_BYTES

        parsed = Psych.safe_load(text, permitted_classes: [Symbol, Date, Time], aliases: false)
        raise Error, "YAML config must be a mapping" unless parsed.is_a?(Hash)

        parsed
      rescue Psych::Exception => e
        raise Error, "Invalid YAML config (#{e.class}: #{e.message})"
      end

      def authorize_config_keys!(keys)
        keys.each do |key|
          perm = CONFIG_KEY_PERMISSIONS[key.to_s]
          raise Error, "Unknown config key: #{key}" unless perm

          Auth.require!(@identity, perm)
        end
      end

      def reject_masked_secrets(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), h|
            next if v.is_a?(String) && v.include?("••••")

            h[k] = reject_masked_secrets(v)
          end
        when Array
          obj.map { |v| reject_masked_secrets(v) }
        else
          obj
        end
      end

      def url(path)
        "#{@script_name}#{path}"
      end

      def cookie_path
        @script_name.empty? ? "/" : @script_name
      end

      def html(template, **locals)
        @title = locals.delete(:title) || "Riggs"
        @locals = locals
        body = render_template(template.to_s, locals)
        layout = render_layout(body)
        [200, { "content-type" => "text/html; charset=utf-8" }, [layout]]
      end

      def render_template(name, locals)
        path = File.join(VIEWS, "#{name}.erb")
        raise Error, "Missing view #{name}" unless File.exist?(path)

        b = binding
        locals.each { |k, v| b.local_variable_set(k, v) }
        ERB.new(File.read(path), trim_mode: "-").result(b)
      end

      def render_layout(content)
        @content = content
        ERB.new(File.read(File.join(VIEWS, "layout.erb")), trim_mode: "-").result(binding)
      end

      # Two different questions, both answered here because every view already
      # routes untrusted text through this one helper. CGI.escapeHTML answers
      # HTML injection; it passes a control byte straight through. Those cannot
      # render in a browser, so dropping them costs nothing on the page, and it
      # keeps the markup from carrying a payload that a copied cell or a "view
      # source" would hand to a terminal. Tab and newline survive, so anything
      # rendered in a <pre> keeps its shape.
      #
      # /api/skills deliberately does NOT go through this: it reports what the
      # file says, and JSON already encodes a control byte correctly on the
      # wire. See docs/gaps.md.
      def h(text)
        CGI.escapeHTML(Riggs.sanitize_for_terminal(text))
      end

      def json_ok(data)
        [200, { "content-type" => "application/json" }, [JSON.generate(data)]]
      end

      def json_error(status, message)
        [status, { "content-type" => "application/json" }, [JSON.generate({ error: message })]]
      end

      def respond_error(req, status, message)
        wants_json =
          @path.to_s.start_with?("/api") ||
          req.get_header("HTTP_ACCEPT").to_s.include?("application/json")
        if wants_json
          json_error(status, message)
        else
          body = "<!doctype html><html><body><h1>#{status}</h1><p>#{h(message)}</p>" \
                 "<p><a href=\"#{h(url('/'))}\">Home</a></p></body></html>"
          [status, { "content-type" => "text/html; charset=utf-8" }, [body]]
        end
      end
    end
  end
end

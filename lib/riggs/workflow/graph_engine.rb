# frozen_string_literal: true

require "securerandom"
require "json"
require "time"
require_relative "../storage"
require_relative "../providers/router"
require_relative "../memory/service"
require_relative "../mcp/manager"
require_relative "loader"
require_relative "tool_loop"

module Riggs
  module Workflow
    class GraphEngine
      CONTEXT_LIMITS = { short: 2, medium: 6, full: 50 }.freeze

      attr_reader :workflow, :user_identity, :session_id, :audit_log, :outputs, :status, :llm_calls

      def initialize(workflow:, user_identity:, storage: nil, db_path: nil, hub_config: {}, gate_handler: nil,
                     provider_router: nil, skill_registry: nil, mcp_manager: nil, mcp_client: nil)
        @workflow = workflow
        @user_identity = user_identity
        @hub_config = hub_config || {}
        @db_path = db_path || @hub_config[:sqlite_path] || "./db/riggs.sqlite3"
        @storage = storage || Storage.new(db_path: @db_path)
        @gate_handler = gate_handler || method(:default_gate_handler)
        @skill_registry = skill_registry
        @mcp_manager = mcp_manager || (mcp_client ? MCP::Manager.wrap_client(mcp_client) : nil)
        @router = provider_router || Providers::Router.new(
          workflow_providers: workflow[:providers],
          hub_providers: @hub_config[:providers] || {},
          audit: ->(**kwargs) { @storage.audit(**kwargs) }
        )
        @outputs = {}
        @audit_log = []
        @status = :pending
        @llm_calls = 0
        @started_at = nil
      end

      def execute(io = $stdout, input: {})
        @started_at = Time.now
        @outputs[:input] = stringify_keys(input)
        report = Loader.validate(@workflow)
        raise WorkflowError, "Invalid workflow: #{report[:errors].join('; ')}" unless report[:valid]

        @session_id = @storage.create_session(
          workflow_name: @workflow[:name],
          user_id: @user_identity[:id],
          memory_namespace: @user_identity[:memory_namespace],
          config_snapshot: {
            max_llm_calls: @workflow[:max_llm_calls],
            context_window: @workflow[:context_window],
            timeout_seconds: @workflow[:timeout_seconds]
          }
        )
        log_event("workflow_start", { workflow: @workflow[:name], user: @user_identity[:id] })
        io.puts "▶ Session #{@session_id}"

        steps_by_id = @workflow[:steps].to_h { |s| [s.id, s] }
        current = @workflow[:steps].first
        @status = :running

        while current
          check_guardrails!

          step_row_id = @storage.create_step(
            session_id: @session_id,
            step_key: current.id,
            label: current.label,
            status: "running",
            input_preview: current.input[0, 200],
            output_var_name: current.output_var
          )

          io.puts "\n── Step: #{current.label} (#{current.id}) ──"

          gate_decision = nil
          if current.approval_gate?
            @storage.update_session(@session_id, status: "awaiting_approval")
            @storage.update_step(step_row_id, status: "awaiting_approval")
            log_event("gate_pause", { step: current.id })
            gate_decision = @gate_handler.call(current, io)
            log_event("gate_decision", { step: current.id, decision: gate_decision })
            @storage.update_step(step_row_id, status: gate_decision.to_s, gate_decided: true)

            if gate_decision == :rejected
              @status = :rejected
              @storage.update_session(@session_id, status: "rejected", ended: true)
              io.puts "⛔ Gate rejected — aborting workflow."
              return self
            end
            @storage.update_session(@session_id, status: "running")
          end

          resolved_input = Loader.resolve_context(current.input, workflow_context)
          system_prompt = build_system_prompt(current)
          messages = build_messages(resolved_input)
          chain = @router.chain_for(step: current, workflow: @workflow)

          loop_runner = ToolLoop.new(
            router: @router,
            mcp_manager: @mcp_manager,
            skill_registry: @skill_registry,
            audit: method(:audit_bridge),
            llm_calls: @llm_calls,
            max_llm_calls: @workflow[:max_llm_calls],
            timeout_seconds: @workflow[:timeout_seconds],
            started_at: @started_at,
            session_id: @session_id
          )

          outcome = loop_runner.run(
            step: current,
            chain: chain,
            messages: messages,
            system_prompt: system_prompt,
            io: io
          )
          @llm_calls = loop_runner.llm_calls
          content = outcome[:content].to_s

          @outputs[current.output_var.to_sym] = content
          @outputs[current.id.to_sym] = { current.output_var.to_sym => content }
          @storage.update_step(step_row_id, status: "completed")
          log_event("step_executed", {
                      step: current.id,
                      provider: outcome[:provider],
                      output_var: current.output_var,
                      preview: content[0, 200]
                    })
          io.puts "✓ Output (#{current.output_var}): #{content[0, 160]}#{'…' if content.length > 160}"

          persist_memory(current, content)

          next_id = Loader.resolve_next(current, outputs: flat_outputs, gate_decision: gate_decision)
          current = next_id ? steps_by_id[next_id] : nil
        end

        @status = :completed
        @storage.update_session(@session_id, status: "completed", ended: true)
        log_event("workflow_complete", { llm_calls: @llm_calls })
        io.puts "\n✅ Workflow completed (#{@llm_calls} LLM calls)."
        self
      rescue StandardError => e
        @status = :failed
        @storage.update_session(@session_id, status: "failed", ended: true) if @session_id
        log_event("workflow_failed", { error: e.message }) if @session_id
        raise
      ensure
        @mcp_manager&.close
      end

      private

      def audit_bridge(session_id:, event_type:, payload: {})
        log_event(event_type, payload)
      end

      def workflow_context
        ctx = { input: @outputs[:input] || {} }
        @outputs.each do |k, v|
          next if k == :input

          ctx[k] = if v.is_a?(Hash)
                     v
                   else
                     { value: v }
                   end
        end
        @workflow[:steps].each do |s|
          val = @outputs[s.output_var.to_sym]
          ctx[s.id.to_sym] ||= {}
          ctx[s.id.to_sym] = ctx[s.id.to_sym].merge(s.output_var.to_sym => val) if val
        end
        ctx
      end

      def flat_outputs
        @outputs.each_with_object({}) do |(k, v), h|
          h[k] = v.is_a?(Hash) ? v.values.first : v
        end
      end

      def build_system_prompt(step)
        parts = ["You are agent '#{step.agent}' in Riggs playbook '#{@workflow[:name]}'."]
        skill_name = step.skill || step.skills.first
        if skill_name && @skill_registry
          skill = @skill_registry.load(skill_name)
          parts << skill[:system_prompt] if skill && skill[:system_prompt]
        end
        parts.join("\n\n")
      end

      def build_messages(resolved_input)
        window = CONTEXT_LIMITS.fetch(@workflow[:context_window], 6)
        recent = @workflow[:steps].map(&:output_var).map(&:to_sym).select { |k| @outputs.key?(k) }.last(window)
        history = recent.map do |var|
          { role: "assistant", content: @outputs[var].to_s }
        end
        history + [{ role: "user", content: resolved_input }]
      end

      def persist_memory(step, content)
        mem_cfg = @hub_config[:sqlite_memory] || {}
        memory = MemoryService.new(
          namespace: @user_identity[:memory_namespace],
          db_path: @db_path,
          config: mem_cfg
        )
        memory.persist(content, context: "#{@workflow[:name]}/#{step.id}")
        memory.close
      rescue StandardError => e
        log_event("memory_error", { error: e.message })
      end

      def check_guardrails!
        if @llm_calls >= @workflow[:max_llm_calls].to_i
          raise WorkflowError, "max_llm_calls (#{@workflow[:max_llm_calls]}) exceeded"
        end
        return unless @started_at && @workflow[:timeout_seconds]

        elapsed = Time.now - @started_at
        raise WorkflowError, "timeout_seconds (#{@workflow[:timeout_seconds]}) exceeded" if elapsed > @workflow[:timeout_seconds]
      end

      def default_gate_handler(step, io)
        io.puts "⏸ HITL gate on '#{step.id}' — Approve / Edit / Reject? [A/E/R]"
        io.print "> "
        answer = if io.respond_to?(:gets) && (line = io.gets)
                   line
                 elsif $stdin.tty?
                   $stdin.gets
                 else
                   "A"
                 end
        case answer.to_s.strip.upcase
        when "E", "EDIT"
          io.puts "Enter edited instruction (single line):"
          edited = ($stdin.tty? ? $stdin.gets : nil).to_s.strip
          @outputs[:gate_edit] = edited unless edited.empty?
          :approved
        when "R", "REJECT"
          :rejected
        else
          :approved
        end
      end

      def log_event(type, payload)
        entry = { event_type: type, payload: payload, at: Time.now.utc.iso8601 }
        @audit_log << entry
        @storage.audit(session_id: @session_id, event_type: type, payload: payload) if @session_id
      end

      def stringify_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v.is_a?(Hash) ? stringify_keys(v) : v }
      end
    end
  end
end

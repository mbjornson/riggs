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
require_relative "compactor"
require_relative "../usage"

module Riggs
  module Workflow
    class GraphEngine
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
        @compaction_announced = false
      end

      # Restarts a paused run from its stored resume_state. The gate that paused
      # the run is treated as already approved, so it does not prompt again.
      def self.resume(session_id:, user_identity:, workflow:, db_path:, hub_config: {}, gate_handler: nil,
                      skill_registry: nil, mcp_manager: nil, storage: nil, io: $stdout)
        new(
          workflow: workflow,
          user_identity: user_identity,
          storage: storage,
          db_path: db_path,
          hub_config: hub_config,
          gate_handler: gate_handler,
          skill_registry: skill_registry,
          mcp_manager: mcp_manager
        ).resume_session(session_id, io: io)
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

        run_steps(@workflow[:steps].first, io)
      rescue StandardError => e
        @status = :failed
        # Audit before the status flips, for the same reason as the success path.
        log_event("workflow_failed", { error: e.message }) if @session_id
        @storage.update_session(@session_id, status: "failed", ended: true) if @session_id
        raise
      ensure
        @mcp_manager&.close
      end

      def resume_session(session_id, io: $stdout)
        session = @storage.find_session(session_id)
        raise WorkflowError, "Session not found: #{session_id}" unless session

        status = session["status"].to_s
        raise WorkflowError, "Session #{session_id} is not paused (status=#{status})" unless status == "paused"

        state = @storage.load_resume_state(session_id)
        raise WorkflowError, "Session #{session_id} has no resume state" unless state

        steps_by_id = @workflow[:steps].to_h { |s| [s.id, s] }
        current = steps_by_id[state[:current_step_id].to_s]
        raise WorkflowError, "Resume step '#{state[:current_step_id]}' is not in workflow '#{@workflow[:name]}'" unless current

        @session_id = session_id
        # timeout_seconds restarts from the resume instant; max_llm_calls does not.
        @started_at = Time.now
        @outputs = state[:outputs].is_a?(Hash) ? state[:outputs] : {}
        @outputs[:input] ||= state[:input] || {}
        @llm_calls = state[:llm_calls].to_i
        # A resumed run is a fresh GraphEngine instance with a fresh
        # @compaction_announced ivar, but the event it guards must land at
        # most once per SESSION, not once per instance -- derived from audit
        # history rather than threaded through resume_state so it is correct
        # even for a session paused before this guard existed.
        @compaction_announced = already_announced_compaction_unavailable?

        # Atomic paused->running claim. The checks above give good error
        # messages, but only this decides who actually runs: a second resumer
        # that passed those same checks concurrently loses here rather than
        # executing the gated step a second time.
        unless @storage.claim_paused_session(session_id)
          raise WorkflowError, "Session #{session_id} was already claimed by another resumer"
        end

        @storage.save_resume_state(session_id, nil)
        log_event("workflow_resume", { step: current.id, llm_calls: @llm_calls })
        io.puts "▶ Resuming session #{session_id} at step '#{current.id}'"

        run_steps(current, io, gate_pre_approved: true)
      rescue StandardError => e
        @status = :failed
        # Audit before the status flips, for the same reason as the success path.
        log_event("workflow_failed", { error: e.message }) if @session_id
        @storage.update_session(@session_id, status: "failed", ended: true) if @session_id
        raise
      ensure
        @mcp_manager&.close
      end

      private

      # Walks the DAG from `current`. `gate_pre_approved` applies only to the
      # first step, so a resumed run does not re-prompt the gate that paused it.
      def run_steps(current, io, gate_pre_approved: false)
        steps_by_id = @workflow[:steps].to_h { |s| [s.id, s] }
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
          if current.approval_gate? && gate_pre_approved
            gate_decision = :approved
            log_event("gate_decision", { step: current.id, decision: gate_decision, resumed: true })
            @storage.update_step(step_row_id, status: "approved", gate_decided: true)
          elsif current.approval_gate?
            @storage.update_session(@session_id, status: "awaiting_approval")
            @storage.update_step(step_row_id, status: "awaiting_approval")
            log_event("gate_pause", { step: current.id })
            gate_decision = @gate_handler.call(current, io)
            log_event("gate_decision", { step: current.id, decision: gate_decision })

            if gate_decision == :paused
              @storage.update_step(step_row_id, status: "paused")
              return pause_run!(current, io)
            end

            # Anything that is neither :paused nor :rejected counts as approval,
            # so a handler returning an unexpected value still follows the
            # "if gate.approved:" branch instead of dead-ending the run.
            gate_decision = :approved unless gate_decision == :rejected

            @storage.update_step(step_row_id, status: gate_decision.to_s, gate_decided: true)

            if gate_decision == :rejected
              @status = :rejected
              @storage.update_session(@session_id, status: "rejected", ended: true)
              io.puts "⛔ Gate rejected — aborting workflow."
              return self
            end
            @storage.update_session(@session_id, status: "running")
          end
          gate_pre_approved = false

          resolved_input = Loader.resolve_context(current.input, workflow_context)
          system_prompt = build_system_prompt(current)
          messages = build_messages(resolved_input)
          chain = @router.chain_for(step: current, workflow: @workflow)
          announce_compaction_availability!(chain)
          persist_bridge(role: "user", content: resolved_input, step_key: current.id)

          loop_runner = ToolLoop.new(
            router: @router,
            mcp_manager: @mcp_manager,
            skill_registry: @skill_registry,
            audit: method(:audit_bridge),
            persist: method(:persist_bridge),
            record_call: method(:record_provider_call),
            compactor: compactor_for(chain),
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
        # Audit first: a poller that sees a terminal status stops reading, so
        # the final event must already exist when the status flips.
        log_event("workflow_complete", { llm_calls: @llm_calls })
        @storage.update_session(@session_id, status: "completed", ended: true)
        io.puts "\n✅ Workflow completed (#{@llm_calls} LLM calls)."
        self
      end

      # A gate pause stops the run before the gated step resolves its input, so
      # the saved state is enough to restart cleanly at the top of that step.
      def pause_run!(step, io)
        @storage.save_resume_state(@session_id, {
                                     current_step_id: step.id,
                                     outputs: @outputs,
                                     llm_calls: @llm_calls,
                                     input: @outputs[:input] || {}
                                   })
        log_event("gate_pause", { step: step.id, resumable: true })
        @storage.update_session(@session_id, status: "paused")
        @status = :paused
        io.puts "⏸ Gate paused on '#{step.id}' — resume with: riggs workflow:resume #{@session_id}"
        self
      end

      def audit_bridge(session_id:, event_type:, payload: {})
        log_event(event_type, payload)
      end

      # The single writer for riggs_provider_calls. ToolLoop receives this as an
      # injected callable; cross-step compaction calls it directly. One writer
      # means the column set cannot drift between the two call sites.
      def record_provider_call(step_key:, provider:, model:, relay_attempt:, usage:, cost_usd:)
        return unless @session_id

        @storage.record_provider_call(
          session_id: @session_id, step_key: step_key, provider: provider, model: model,
          relay_attempt: relay_attempt, usage: usage, cost_usd: cost_usd
        )
      end

      # Writes one conversation turn as it happens; seq is allocated by Storage.
      def persist_bridge(role:, content:, step_key:, tool_call_id: nil, tool_name: nil, tool_calls: nil, provider: nil)
        return unless @session_id

        @storage.append_message(
          session_id: @session_id,
          step_key: step_key,
          role: role,
          content: content,
          tool_call_id: tool_call_id,
          tool_name: tool_name,
          tool_calls: tool_calls,
          provider: provider
        )
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

      # Selects prior step outputs by token budget rather than step count.
      # The walk is newest-to-oldest; a turn that would push the total over
      # the ceiling is skipped rather than stopping the walk, so history can
      # end up non-contiguous -- an older turn that fits is kept even when a
      # newer one did not. The emitted array is chronological -- a provider
      # reading it in selection order would see the conversation backwards.
      def build_messages(resolved_input)
        ceiling = compactor.ceiling(model: nil)
        vars = @workflow[:steps].map(&:output_var).map(&:to_sym).select { |k| @outputs.key?(k) }

        kept = []
        used = Usage.estimate([{ role: "user", content: resolved_input }])
        vars.reverse_each do |var|
          turn = { role: "assistant", content: @outputs[var].to_s }
          size = Usage.estimate([turn])
          next if used + size > ceiling

          used += size
          kept.unshift(turn)
        end

        kept + [{ role: "user", content: resolved_input }]
      end

      # build_messages only needs #ceiling, which never reads @chain, so any
      # step's chain would do here -- the first step's is as good as any.
      def compactor
        compactor_for(@router.chain_for(step: @workflow[:steps].first, workflow: @workflow))
      end

      # Memoized per chain, not globally: Router#chain_for honors a step's own
      # relay_chain/provider override, and Compactor#compact routes its
      # summarization call through @chain. A single first-step-only Compactor
      # would silently summarize every later step's transcript through the
      # first step's provider chain instead of its own the moment ToolLoop
      # starts calling #compact. Most workflows share one chain across steps,
      # so this cache still collapses to a single Compactor in the common case.
      def compactor_for(chain)
        key = Array(chain).map(&:to_s)
        @compactors ||= {}
        @compactors[key] ||= Compactor.new(
          router: @router,
          chain: key,
          budget: @workflow[:context_window],
          reserve: @workflow[:reserve_tokens],
          keep_recent: @workflow[:keep_recent_tokens],
          record_call: method(:record_provider_call),
          session_id: @session_id
        )
      end

      # No provider on this chain reports usage, so there is no anchor and
      # compaction can never trigger. Announced once per run: silent
      # non-compaction looks exactly like compaction that is working.
      def announce_compaction_availability!(chain)
        return if @compaction_announced
        return unless Providers::Router.unmetered_chain?(chain)

        @compaction_announced = true
        log_event("compaction_unavailable", { chain: Array(chain).map(&:to_s) })
      end

      # Storage, not resume_state, is the source of truth for "has this
      # session already announced" -- resume_state is only written at pause
      # time (fine for the common case), but a plain audit-history check also
      # covers a session paused before this guard shipped, and any future
      # resume path that does not happen to round-trip through pause_run!.
      def already_announced_compaction_unavailable?
        @storage.list_audit(@session_id).any? { |row| row["event_type"] == "compaction_unavailable" }
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

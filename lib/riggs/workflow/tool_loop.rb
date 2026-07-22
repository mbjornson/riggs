# frozen_string_literal: true

require "json"
require "securerandom"

module Riggs
  module Workflow
    # Multi-turn provider ↔ MCP tool execution until final text or guardrails.
    class ToolLoop
      def initialize(router:, mcp_manager:, skill_registry:, audit:, llm_calls:, max_llm_calls:, timeout_seconds:, started_at:,
                     session_id:)
        @router = router
        @mcp_manager = mcp_manager
        @skill_registry = skill_registry
        @audit = audit
        @llm_calls = llm_calls
        @max_llm_calls = max_llm_calls.to_i
        @timeout_seconds = timeout_seconds
        @started_at = started_at
        @session_id = session_id
      end

      attr_reader :llm_calls

      def run(step:, chain:, messages:, system_prompt:, io:)
        skill = load_skill(step)
        tools = resolve_tools(skill)
        sys = system_prompt.dup
        if tools.any? && cli_only_chain?(chain)
          sys = "#{sys}\n\nAvailable tools (respond with TOOL:name|{json} to call):\n" +
                tools.map { |t| "- #{t[:name]}: #{t[:description]}" }.join("\n")
        end

        loop do
          check_guardrails!
          result = @router.call(
            chain: chain,
            messages: messages,
            system: sys,
            timeout: remaining_timeout,
            session_id: @session_id,
            tools: tools.empty? ? nil : tools
          )
          @llm_calls += 1

          tool_calls = Array(result[:tool_calls])
          tool_calls = parse_tool_line(result[:content]) if tool_calls.empty? && result[:content].to_s.start_with?("TOOL:")

          return { content: result[:content].to_s, provider: result[:provider], llm_calls: @llm_calls } if tool_calls.empty?

          # Append assistant turn with tool_calls for provider follow-up
          messages << {
            role: "assistant",
            content: result[:content].to_s,
            tool_calls: tool_calls
          }

          tool_calls.each do |tc|
            @audit.call(session_id: @session_id, event_type: "tool_call",
                        payload: { step: step.id, tool: tc[:name], args: tc[:arguments] })
            io.puts "  🔧 tool #{tc[:name]}(#{tc[:arguments].inspect[0, 80]})"
            out = execute_tool(tc, skill)
            @audit.call(session_id: @session_id, event_type: "tool_result",
                        payload: { step: step.id, tool: tc[:name], preview: out.to_s[0, 200] })
            io.puts "     → #{out.to_s[0, 100]}"
            messages << {
              role: "tool",
              name: tc[:name],
              tool_call_id: tc[:id],
              id: tc[:id],
              content: out.to_s
            }
          end
        end
      end

      private

      def load_skill(step)
        return nil unless @skill_registry

        name = step.skill || step.skills.first
        return nil unless name

        @skill_registry.load(name)
      end

      def resolve_tools(skill)
        skill_tools = skill ? Array(skill[:tools]).map { |t| Identity.deep_symbolize(t) } : []
        allowed_servers = skill ? Array(skill[:mcp_servers]).map(&:to_s) : []

        mcp_tools = []
        if @mcp_manager
          listed = @mcp_manager.list_tools
          listed = listed.select { |mt| allowed_servers.include?(mt[:server]) } unless allowed_servers.empty?

          listed.each do |mt|
            skill_ref = skill_tools.find { |t| t[:name] == mt[:name] }
            # Include when the skill lists this tool, pins this server, or no skill
            # constrains tools; a skill without mcp_servers keeps only its own tools.
            next unless skill_ref || !allowed_servers.empty? || skill.nil?

            mcp_tools << {
              name: mt[:name],
              description: (skill_ref && !skill_ref[:description].to_s.empty? ? skill_ref[:description] : mt[:description]),
              input_schema: (skill_ref && skill_ref[:input_schema]) || mt[:input_schema],
              mcp_server: mt[:server]
            }
          end
        end

        # Skill-local tools (no mcp_server) always available
        local = skill_tools.select { |t| t[:mcp_server].nil? || t[:mcp_server].to_s.empty? }
        # Skill tools that reference mcp_server but weren't discovered stay as stubs (executed may fail)
        pending_mcp = skill_tools.select do |t|
          t[:mcp_server] && !t[:mcp_server].to_s.empty? && mcp_tools.none? do |m|
            m[:name] == t[:name]
          end
        end

        (local + mcp_tools + pending_mcp).uniq { |t| t[:name] }
      end

      def execute_tool(tc, skill)
        name = tc[:name].to_s
        args = tc[:arguments] || {}

        # Built-in local stub
        if name == "lookup_runbook"
          topic = args[:topic] || args["topic"] || "general"
          return "Runbook[#{topic}]: Check credentials, rotate tokens, verify upstream health."
        end

        if @mcp_manager
          server = nil
          if skill
            ref = Array(skill[:tools]).find { |t| t[:name].to_s == name }
            server = ref[:mcp_server] if ref
          end
          return @mcp_manager.call_tool(name, args, server: server)
        end

        "TOOL_ERROR: no MCP manager and no built-in for #{name}"
      rescue StandardError => e
        "TOOL_ERROR: #{e.message}"
      end

      def cli_only_chain?(chain)
        Array(chain).all? { |n| %w[cursor cursor_cli claude_cli anthropic_cli codex openai_cli].include?(n.to_s) }
      end

      def parse_tool_line(content)
        line = content.to_s.sub(/\ATOOL:/, "")
        tname, raw_args = line.split("|", 2)
        args = raw_args && !raw_args.empty? ? JSON.parse(raw_args) : {}
        [{ id: "tool_#{SecureRandom.hex(4)}", name: tname.strip, arguments: args }]
      rescue JSON::ParserError
        [{ id: "tool_#{SecureRandom.hex(4)}", name: tname.to_s.strip, arguments: {} }]
      end

      def check_guardrails!
        if @llm_calls >= @max_llm_calls
          @audit.call(session_id: @session_id, event_type: "tool_loop_exhausted", payload: { reason: "max_llm_calls" })
          raise WorkflowError, "max_llm_calls (#{@max_llm_calls}) exceeded"
        end
        return unless @started_at && @timeout_seconds

        return unless Time.now - @started_at > @timeout_seconds

        @audit.call(session_id: @session_id, event_type: "tool_loop_exhausted", payload: { reason: "timeout" })
        raise WorkflowError, "timeout_seconds (#{@timeout_seconds}) exceeded"
      end

      def remaining_timeout
        return @timeout_seconds unless @started_at && @timeout_seconds

        left = @timeout_seconds - (Time.now - @started_at)
        [left, 1].max
      end
    end
  end
end

# frozen_string_literal: true

require_relative "base"
require_relative "mock"
require_relative "anthropic"
require_relative "openai_compatible"
require_relative "cursor_cli"
require_relative "claude_cli"
require_relative "codex_cli"
require_relative "cursor_cloud"
require_relative "../usage"
require_relative "../model_info"

module Riggs
  module Providers
    class Router
      BUILTINS = {
        "mock" => Mock,
        "anthropic" => Anthropic,
        "claude" => Anthropic,
        "openai" => OpenAICompatible,
        "openai_compatible" => OpenAICompatible,
        "ollama" => OpenAICompatible,
        "cursor" => CursorCli,
        "cursor_cli" => CursorCli,
        "cursor_cloud" => CursorCloud,
        "claude_cli" => ClaudeCli,
        "anthropic_cli" => ClaudeCli,
        "codex" => CodexCli,
        "openai_cli" => CodexCli
      }.freeze

      def initialize(workflow_providers: {}, hub_providers: {}, audit: nil, registry: nil)
        @workflow_providers = Identity.deep_symbolize(workflow_providers || {})
        @hub_providers = Identity.deep_symbolize(hub_providers || {})
        @audit = audit
        @registry = registry || BUILTINS
      end

      def call(chain:, messages:, system: nil, timeout: 60, session_id: nil, tools: nil)
        names = Array(chain).map(&:to_s)
        names = ["mock"] if names.empty?
        last_error = nil

        names.each_with_index do |name, idx|
          provider = build(name)
          result = provider.complete(messages: messages, system: system, timeout: timeout, tools: tools)
          result[:tool_calls] ||= []
          metered = meter(result, name)
          @audit&.call(
            session_id: session_id,
            event_type: "provider_success",
            payload: { provider: name, attempt: idx + 1,
                       tokens: metered[:usage][:total_tokens], cost_usd: metered[:cost_usd] }
          )
          return metered.merge(relay_attempt: idx + 1)
        rescue RateLimitError, TimeoutError, Error => e
          last_error = e
          @audit&.call(
            session_id: session_id,
            event_type: "provider_failover",
            payload: { provider: name, attempt: idx + 1, error: e.class.name, message: e.message }
          )
          next
        end

        raise Error, "All providers in relay_chain failed: #{last_error&.message}"
      end

      def chain_for(step:, workflow:)
        # Step-level relay_chain override (Struct may not have relay_chain — read from options hash if present)
        if step.respond_to?(:relay_chain) && step.relay_chain && !Array(step.relay_chain).empty?
          return Array(step.relay_chain).map(&:to_s)
        end

        if step.provider && !step.provider.empty?
          # Named chain lookup: provider: "default" or a hub/workflow alias with relay_chain
          named = provider_config(step.provider)
          return Array(named[:relay_chain]).map(&:to_s) if named[:relay_chain]

          return [step.provider.to_s]
        end

        default = workflow.dig(:providers, :default) || workflow.dig(:providers, "default") || {}
        default = Identity.deep_symbolize(default)
        chain = default[:relay_chain] || ["mock"]
        Array(chain).map(&:to_s)
      end

      private

      def build(name)
        key = name.to_s
        opts = provider_config(key)

        if key == "ollama"
          opts[:base_url] ||= ENV["OLLAMA_BASE_URL"] || "http://127.0.0.1:11434/v1"
          opts[:model] ||= ENV["OLLAMA_MODEL"] || "llama3"
        end

        type_key = opts[:type]&.to_s || key
        klass = @registry[key] || @registry[type_key]
        raise Error, "Unknown provider '#{key}' (no registry entry for '#{key}' or type '#{type_key}')" unless klass

        klass.new(name: key, options: opts)
      end

      # Merge: hub ← workflow (workflow wins on conflict)
      def provider_config(name)
        key = name.to_s
        hub = @hub_providers[key.to_sym] || @hub_providers[key] || {}
        wf = @workflow_providers[key.to_sym] || @workflow_providers[key] || {}
        hub = {} unless hub.is_a?(Hash)
        wf = {} unless wf.is_a?(Hash)
        Identity.deep_symbolize(hub).merge(Identity.deep_symbolize(wf))
      end

      # Normalizes vendor usage and prices it. Only Router resolves provider
      # config, so the per-model pricing override is only reachable here.
      def meter(result, name)
        opts = provider_config(name)
        usage = Usage.normalize(result[:usage])
        overrides = opts[:pricing] || {}
        result.merge(
          usage: usage,
          cost_usd: ModelInfo.cost(model: result[:model], usage: usage, overrides: overrides)
        )
      end
    end
  end
end

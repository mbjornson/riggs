# frozen_string_literal: true

require_relative "base"
require_relative "mock"
require_relative "anthropic"
require_relative "openai_compatible"
require_relative "cli"
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

      # Providers that return no token usage, so nothing downstream can measure
      # or compact a conversation running on them.
      UNMETERED = %w[cursor cursor_cli cursor_cloud claude_cli anthropic_cli codex openai_cli cli].freeze

      # Fields a workflow file may not set, because a workflow file travels
      # with a repository just like the project config that is already barred
      # from setting them (Config::Merge::PROVIDER_FIELDS). base_url is where
      # the credential goes: OpenAICompatible sends the operator's key to it as
      # a bearer token, so a workflow naming another host collects it. Pricing
      # is the same shape of problem in a different currency and is handled by
      # #pricing_for, which predates this list.
      OPERATOR_ONLY_FIELDS = %i[base_url].freeze

      def self.unmetered_chain?(chain)
        names = Array(chain).map(&:to_s)
        !names.empty? && names.all? { |n| UNMETERED.include?(n) }
      end

      def initialize(workflow_providers: {}, hub_providers: {}, audit: nil, registry: nil)
        @workflow_providers = Identity.deep_symbolize(workflow_providers || {})
        @hub_providers = Identity.deep_symbolize(hub_providers || {})
        @audit = audit
        @registry = registry || BUILTINS
      end

      # `on_failed_attempt` is invoked once per dispatched attempt that raised,
      # immediately, with the provider name and 1-based attempt number. A
      # provider that accepted and billed a request before timing out on the
      # read is real spend; metering only the attempt that RETURNED left that
      # spend out of the ledger entirely, so session coverage reported a
      # complete count over a denominator that had already dropped the failure.
      # Reported as it happens rather than returned, so the case where every
      # provider fails -- which raises instead of returning -- is covered too.
      def call(chain:, messages:, system: nil, timeout: 60, session_id: nil, tools: nil,
               on_failed_attempt: nil)
        names = Array(chain).map(&:to_s)
        names = ["mock"] if names.empty?
        validate_auth_modes!(names)
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
          notify_failed_attempt(on_failed_attempt, name, idx + 1, e)
          next
        rescue StandardError => e
          # Not a relay error, so it does NOT fail over -- an unexpected
          # exception propagates and the run dies. The attempt was still
          # dispatched and still spent, so it is ledgered on the way out.
          notify_failed_attempt(on_failed_attempt, name, idx + 1, e)
          raise
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

      # Every configured provider mapped to the account it will bill. Recorded
      # once per run rather than per call: auth mode is a property of provider
      # configuration, and riggs_provider_calls already records which provider
      # answered each call, so the two together recover the billing account for
      # every step -- without a schema change, which riggs_provider_calls has no
      # migration path for.
      #
      # This is an observability field, so it must not be able to abort the run
      # it observes -- see #provider_auth_mode for why the rescue there gives up
      # nothing: the money-safety guard is #validate_auth_modes!, which runs
      # before dispatch and outside the relay rescue.
      #
      # A name whose config is a routing directive (providers.default and any
      # other relay_chain alias, hub- or workflow-level) is not itself a
      # dispatchable provider -- #chain_for never passes it to #build, it only
      # unpacks its relay_chain into other providers' names -- so
      # #provider_auth_mode returns nil for it and it is left out of the map
      # entirely, rather than reported under a name no call in
      # riggs_provider_calls.provider can ever match.
      def auth_modes
        configured = (@hub_providers.keys + @workflow_providers.keys).map(&:to_s)
        names = (configured + relay_chain_members).uniq.sort
        names.each_with_object({}) do |name, modes|
          mode = provider_auth_mode(name)
          modes[name] = mode if mode
        end
      end

      private

      # Never raises. A broken ledger callback must not convert a recoverable
      # failover into a failed run -- the next provider in the chain may well
      # answer, and the whole point of this hook is bookkeeping.
      def notify_failed_attempt(callback, provider, attempt, error)
        callback&.call(provider: provider, attempt: attempt, error: error)
      rescue StandardError
        nil
      end

      def build(name)
        key = name.to_s
        opts = provider_config(key)

        if key == "ollama"
          opts[:base_url] ||= ENV["OLLAMA_BASE_URL"] || "http://127.0.0.1:11434/v1"
          opts[:model] ||= ENV["OLLAMA_MODEL"] || "llama3"
        end

        klass = provider_class_for(key, opts)
        unless klass
          raise Error,
                "Unknown provider '#{key}' (no registry entry for '#{key}' or type '#{opts[:type]&.to_s || key}')"
        end

        klass.new(name: key, options: opts)
      end

      # The one place Router turns a configured name into a class. #build,
      # #validate_auth_modes! and #provider_auth_mode all resolve through it,
      # which is what keeps the audit map and the pre-dispatch guard describing
      # the provider that actually gets dispatched. Three hand-copies of this
      # lookup could drift apart silently and the map would start lying.
      def provider_class_for(key, opts)
        @registry[key.to_s] || @registry[opts[:type]&.to_s || key.to_s]
      end

      # An invalid `auth:` is a configuration error, not a provider failure, so
      # it must not participate in failover. It is checked HERE, before the
      # dispatch loop, because that loop rescues Error and relays -- including
      # the raise Cli#auth_mode makes from inside child_env. Relaying a typo is
      # the exact silent spend spec Decision 2 exists to prevent: a chain of
      # [claude_cli(auth: "subscrption"), anthropic] answered on anthropic and
      # billed ANTHROPIC_API_KEY, reporting nothing. Every name in the chain is
      # validated up front, not lazily per attempt, because a fallback that is
      # only reached when the primary fails is exactly when nobody is watching.
      # No relay_chain skip here, deliberately. Every name this receives is a
      # name #call is about to hand to #build, so it is dispatchable by
      # definition -- a relay_chain key on it does not make it a routing
      # directive the way it does in #provider_auth_mode, which enumerates
      # config rather than a chain. Skipping on it reopened the hole this guard
      # exists to close.
      def validate_auth_modes!(names)
        names.each do |name|
          opts = provider_config(name)
          klass = provider_class_for(name, opts)
          next unless klass
          next unless klass.respond_to?(:resolve_auth_mode)

          klass.resolve_auth_mode(opts[:auth], provider: name)
        end
      end

      # Names that appear only inside a relay_chain are still dispatched --
      # #build resolves them from BUILTINS with no config entry of their own --
      # and riggs_provider_calls records them by name. Omitting them made
      # #auth_modes return {} for the commonest workflow shape there is, a
      # providers: block holding nothing but default.relay_chain, which is
      # precisely when the join the map exists for is needed.
      def relay_chain_members
        [@hub_providers, @workflow_providers].flat_map do |providers|
          providers.each_value.flat_map do |opts|
            opts.is_a?(Hash) ? Array(opts[:relay_chain]).map(&:to_s) : []
          end
        end
      end

      # Merge: hub <- workflow (workflow wins on conflict), except for the
      # fields below, which the workflow may not move at all.
      def provider_config(name)
        hub = Identity.deep_symbolize(entry(@hub_providers, name))
        merged = hub.merge(Identity.deep_symbolize(entry(@workflow_providers, name)))
        OPERATOR_ONLY_FIELDS.each { |field| apply_operator_field(merged, hub, field) }
        merged
      end

      # Deleted when the operator did not set it, not merely left alone: the
      # guarantee is "the workflow cannot choose this", and letting a workflow
      # supply the value whenever the operator omitted it is the same redirect
      # with an extra precondition.
      def apply_operator_field(merged, hub, field)
        return merged.delete(field) unless hub.key?(field)

        merged[field] = hub[field]
      end

      # One lookup for both maps. These were two near-copies, and the endpoint
      # bug was exactly that pricing_for grew a hub-only rule while the copy
      # next to it did not.
      def entry(map, name)
        key = name.to_s
        found = map[key.to_sym] || map[key] || {}
        return {} unless found.is_a?(Hash)

        found
      end

      # Non-CLI providers take an API key by definition, so a stray `auth:` on
      # one is ignored rather than validated (R9.1) -- there is no CLI to defer
      # to. A CLI provider with an invalid `auth:` is stopped by
      # #validate_auth_modes! before anything dispatches; that, not this
      # method, is the money-safety guard. (Cli#auth_mode raises from inside
      # child_env too, but #call's dispatch loop rescues Error and relays, so
      # that raise fails over to the next provider instead of failing the run
      # -- it is not a guard.) Rescued here per provider name, not around the
      # whole #auth_modes loop, so one bad entry does not blank out the good
      # ones. "invalid" is deliberately outside Cli::AUTH_MODES: it can only
      # appear for a provider that was configured but never dispatched.
      #
      # Returns nil for a routing directive (a relay_chain alias, e.g.
      # providers.default) rather than "api": #chain_for's own named-lookup
      # branch treats a `relay_chain` key as the entry's whole identity
      # (`return ... if named[:relay_chain]`, checked before any type/registry
      # resolution and never reached again) so this mirrors, key for key, the
      # one place Router already decides "is this name a real provider or a
      # chain to unpack."
      def provider_auth_mode(name)
        opts = provider_config(name)
        return nil if opts[:relay_chain]

        klass = provider_class_for(name, opts)
        return nil unless klass
        return nil unless klass.respond_to?(:resolve_auth_mode)

        klass.resolve_auth_mode(opts[:auth], provider: name)
      rescue Error
        "invalid"
      end

      # Normalizes vendor usage and prices it. Only Router resolves provider
      # config, so the per-model pricing override is only reachable here.
      def meter(result, name)
        usage = Usage.normalize(result[:usage])
        result.merge(
          usage: usage,
          cost_usd: ModelInfo.cost(model: result[:model], usage: usage, overrides: pricing_for(name))
        )
      end

      # Pricing comes from the HUB config alone, deliberately not through
      # #provider_config -- which merges hub <- workflow and lets the workflow
      # win, as every other field should. A workflow file travels with a
      # repository, so that merge let a clone declare its own prices and
      # report $0.00 for a run that cost $60.00. riggs exists to tell the
      # operator what their agents cost, so pricing is the operator's the same
      # way credentials are; Config::Merge::PROVIDER_FIELDS is the matching
      # guard for the project config tier.
      # Not deep_symbolized on purpose: these keys are MODEL NAMES, and
      # symbolizing them makes "gpt-4" stop matching the model actually being
      # priced.
      def pricing_for(name)
        entry(@hub_providers, name)[:pricing] || {}
      end
    end
  end
end

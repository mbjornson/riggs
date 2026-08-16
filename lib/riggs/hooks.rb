# frozen_string_literal: true

module Riggs
  # Ordered interception points for provider requests and tool execution.
  # Handlers mutate the context hash in place; fire returns that same hash.
  class Hooks
    EVENTS = %i[before_provider_request tool_call tool_result].freeze

    def initialize
      @handlers = EVENTS.to_h { |e| [e, []] }
    end

    def on(event, &block)
      register(event, block)
    end

    def register(event, callable)
      key = normalize_event(event)
      raise ArgumentError, "unknown hook event: #{event}" unless @handlers.key?(key)
      raise ArgumentError, "hook handler must respond to call" unless callable.respond_to?(:call)

      @handlers[key] << callable
      self
    end

    def fire(event, ctx)
      key = normalize_event(event)
      raise ArgumentError, "unknown hook event: #{event}" unless @handlers.key?(key)

      context = ctx.is_a?(Hash) ? ctx : {}
      @handlers[key].each do |handler|
        handler.call(context)
        break if key == :tool_call && context[:deny]
      end
      context
    end

    # Default bus: deny non-builtin (MCP) tools when the identity lacks manage_mcp.
    def self.default(identity: nil)
      hooks = new
      hooks.on(:tool_call) do |ctx|
        next if ctx[:deny]
        next if ctx[:builtin]
        next if identity.nil?
        next if Identity.permitted?(identity, "manage_mcp")

        role = identity[:role]
        ctx[:deny] = "role '#{role}' lacks manage_mcp for tool '#{ctx[:name]}'"
      end
      hooks
    end

    private

    def normalize_event(event)
      event.to_sym
    end
  end
end

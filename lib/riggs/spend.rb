# frozen_string_literal: true

module Riggs
  # One money string, computed in ONE place. `riggs projects` and `riggs cost`
  # both print spend, and the rule they have to share is the sharp one:
  #
  # Router::UNMETERED covers every CLI provider, so those calls store a NULL
  # cost_usd and a project running entirely on a subscription SUMs to NULL.
  # Rendering that as $0.00 is a false record -- work really billed to a
  # subscription, reported as billed to nobody. It is the same defect as
  # `auth: none` on a CLI provider, which Phase 10 removed for this reason.
  #
  # So every figure carries its denominator: priced work as a dollar amount,
  # unmetered calls counted beside it and never folded in.
  class Spend
    NONE = "—"

    def self.of(cost_usd:, unmetered_calls:)
      new(cost_usd: cost_usd, unmetered_calls: unmetered_calls).to_s
    end

    def initialize(cost_usd:, unmetered_calls:)
      @cost_usd = cost_usd
      @unmetered_calls = unmetered_calls.to_i
    end

    def to_s
      return "#{NONE}#{unmetered}" if @cost_usd.nil?

      "$#{format('%.4f', @cost_usd)}#{unmetered}"
    end

    private

    def unmetered
      return "" if @unmetered_calls.zero?
      return " (#{@unmetered_calls} unmetered)" if @cost_usd.nil?

      " + #{@unmetered_calls} unmetered"
    end
  end
end

# frozen_string_literal: true

module Riggs
  # Per-model prices and context windows.
  #
  # Pricing and context window are one table rather than two, because they are
  # keyed identically and two parallel tables could disagree about which models
  # exist. Prices are USD per 1,000,000 tokens.
  #
  # AS_OF makes staleness visible. `.agent_hubrc` overrides win, so anyone on
  # negotiated rates or a self-hosted model is never bound to these numbers.
  #
  # Sourced from vendor documentation on AS_OF (see task-2-report.md for the
  # full provenance trail: URLs fetched, and which model/price came from
  # which page). cache_write uses each vendor's shortest-lived / base cache
  # write price (Anthropic: 5-minute cache write). Where a vendor has no
  # concept of a cache write charge (OpenAI's caching is automatic and free
  # to write), cache_write is nil rather than 0 — 0 would claim a price that
  # was actually observed and confirmed free.
  module ModelInfo
    AS_OF = "2026-08-04"

    TABLE = {
      # Anthropic -- https://platform.claude.com/docs/en/about-claude/pricing
      # and https://platform.claude.com/docs/en/about-claude/models/overview
      "claude-fable-5" => { input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5,
                            context_window: 1_000_000 },
      "claude-mythos-5" => { input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5,
                             context_window: 1_000_000 },
      "claude-opus-5" => { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25,
                           context_window: 1_000_000 },
      "claude-opus-4-8" => { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25,
                             context_window: 1_000_000 },
      "claude-opus-4-7" => { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25,
                             context_window: 1_000_000 },
      "claude-opus-4-6" => { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25,
                             context_window: 1_000_000 },
      "claude-opus-4-5-20251101" => { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25,
                                      context_window: 200_000 },
      "claude-opus-4-1-20250805" => { input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75,
                                      context_window: 200_000 },
      "claude-opus-4-20250514" => { input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75,
                                    context_window: 200_000 },
      # Introductory pricing, active through 2026-08-31; standard $3/$15 begins 2026-09-01.
      "claude-sonnet-5" => { input: 2.0, output: 10.0, cache_read: 0.2, cache_write: 2.5,
                             context_window: 1_000_000 },
      "claude-sonnet-4-6" => { input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75,
                               context_window: 1_000_000 },
      "claude-sonnet-4-5-20250929" => { input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75,
                                        context_window: 200_000 },
      "claude-sonnet-4-20250514" => { input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75,
                                      context_window: 200_000 },
      "claude-haiku-4-5-20251001" => { input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25,
                                       context_window: 200_000 },
      "claude-3-5-haiku-20241022" => { input: 0.80, output: 4.0, cache_read: 0.08, cache_write: 1.0,
                                       context_window: 200_000 },

      # OpenAI -- https://developers.openai.com/api/docs/pricing and
      # https://developers.openai.com/api/docs/models/gpt-4o-mini
      "gpt-4o-mini" => { input: 0.15, output: 0.60, cache_read: 0.075, cache_write: nil,
                         context_window: 128_000 }
    }.freeze

    PER_MILLION = 1_000_000.0

    RATE_FIELDS = {
      input_tokens: :input,
      output_tokens: :output,
      cache_read_tokens: :cache_read,
      cache_write_tokens: :cache_write
    }.freeze

    def self.lookup(model, overrides: {})
      return nil if model.nil? || model.to_s.empty?

      key = model.to_s
      shipped = TABLE[key]
      override = normalize_overrides(overrides)[key]
      return nil if shipped.nil? && override.nil?

      (shipped || {}).merge(override || {})
    end

    def self.context_window(model, overrides: {})
      lookup(model, overrides: overrides)&.fetch(:context_window, nil)
    end

    # Returns nil — never 0 — when the call was unmeasured or the model has no
    # price entry. A zero would be indistinguishable from a genuinely free call.
    def self.cost(model:, usage:, overrides: {})
      return nil unless usage.is_a?(Hash) && usage[:measured]

      rates = lookup(model, overrides: overrides)
      return nil if rates.nil?

      total = RATE_FIELDS.sum do |usage_key, rate_key|
        tokens = usage[usage_key]
        rate = rates[rate_key]
        tokens.nil? || rate.nil? ? 0.0 : (tokens / PER_MILLION) * rate
      end
      total.to_f
    end

    def self.normalize_overrides(overrides)
      return {} unless overrides.is_a?(Hash)

      overrides.each_with_object({}) do |(model, rates), acc|
        next unless rates.is_a?(Hash)

        acc[model.to_s] = rates.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end
    end

    private_class_method :normalize_overrides
  end
end

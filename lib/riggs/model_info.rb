# frozen_string_literal: true

require "date"

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
  #
  # An entry may carry a `promotional:` block — a time-boxed overlay of the
  # form `{ input:, output:, cache_read:, cache_write:, until: "YYYY-MM-DD" }`
  # (see task-2b-report.md for provenance). `until` is inclusive. `lookup`
  # resolves it against `at:` (a Date, an ISO date String, or nil for
  # Date.today) in this order: shipped base, then the promotional rates if
  # still live at `at`, then caller `overrides` last — overrides always win,
  # so a negotiated rate is never silently clobbered by a vendor promo. This
  # shape self-heals: once `at` passes `until`, the base rate takes over with
  # no table edit required.
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
      # Standard pricing. Introductory pricing ($2/$10) is active through 2026-08-31
      # via the `promotional:` overlay below; standard $3/$15 begins 2026-09-01.
      "claude-sonnet-5" => { input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75,
                             context_window: 1_000_000,
                             promotional: { input: 2.0, output: 10.0, cache_read: 0.2,
                                            cache_write: 2.5, until: "2026-08-31" } },
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

    def self.lookup(model, overrides: {}, at: nil)
      return nil if model.nil? || model.to_s.empty?

      key = model.to_s
      normalized = normalize_overrides(overrides)
      shipped = resolve_promotional(TABLE[resolve_key(key, TABLE)], at)
      override = normalized[resolve_key(key, normalized)]
      return nil if shipped.nil? && override.nil?

      (shipped || {}).merge(override || {})
    end

    # Providers report the model the API actually served, which is routinely a
    # dated build ID (`gpt-4o-mini-2024-07-18`) that no shipped table can
    # enumerate ahead of time. Exact-match-only lookup therefore left every
    # real OpenAI call unpriced while its undated alias priced fine.
    #
    # Exact match wins. Otherwise the model must be the longest table key plus
    # a "-" and a suffix: the trailing hyphen keeps `gpt-4o-mini` from
    # answering for `gpt-4o-miniature`, and "longest" keeps a dated
    # `claude-opus-4-6-*` from resolving to some shorter family prefix. A key
    # is never invented -- an unknown family still returns nil.
    def self.resolve_key(model, table)
      return model if table.key?(model)

      table.keys.select { |k| model.start_with?("#{k}-") }.max_by(&:length)
    end

    def self.context_window(model, overrides: {}, at: nil)
      lookup(model, overrides: overrides, at: at)&.fetch(:context_window, nil)
    end

    # Returns nil — never 0 — when the call was unmeasured or the model has no
    # price entry. A zero would be indistinguishable from a genuinely free call.
    def self.cost(model:, usage:, overrides: {}, at: nil)
      return nil unless usage.is_a?(Hash) && usage[:measured]

      rates = lookup(model, overrides: overrides, at: at)
      return nil if rates.nil?
      return nil if RATE_FIELDS.values.all? { |k| rates[k].nil? }

      priced_total(usage, rates)
    end

    # A category with tokens but no rate makes the TOTAL unknowable, not free.
    # Treating it as 0.0 (the original behaviour) reported a confident dollar
    # figure that silently excluded measured, billable tokens -- the "unpriced
    # is nil, never 0" invariant broken from the inside, since the model DID
    # have an entry and DID price some other category.
    #
    # Zero tokens in an unpriced category is a different case and must not nil
    # the call: OpenAI has no cache-write price at all and reports zero cache
    # writes on every request, so being strict there would unprice every
    # OpenAI call. Zero unpriceable tokens cost a knowable nothing.
    def self.priced_total(usage, rates)
      total = 0.0
      RATE_FIELDS.each do |usage_key, rate_key|
        tokens = usage[usage_key]
        next if tokens.nil? || tokens.zero?

        rate = rates[rate_key]
        return nil if rate.nil?

        total += (tokens / PER_MILLION) * rate
      end
      total
    end

    # Resolves a shipped TABLE entry's `promotional:` overlay against `at`, and
    # always strips the `promotional:` key from the result — the returned hash
    # is a flat rate hash, never a nested one. Entries without a `promotional:`
    # block, and nil entries (unknown model), pass through unchanged.
    def self.resolve_promotional(entry, at)
      return nil if entry.nil?

      promo = entry[:promotional]
      base = entry.except(:promotional)
      return base if promo.nil?

      resolve_at(at) <= Date.parse(promo[:until].to_s) ? base.merge(promo.except(:until)) : base
    end

    def self.resolve_at(at)
      return Date.today if at.nil?
      return at if at.is_a?(Date)

      Date.parse(at.to_s)
    end

    def self.normalize_overrides(overrides)
      return {} unless overrides.is_a?(Hash)

      overrides.each_with_object({}) do |(model, rates), acc|
        next unless rates.is_a?(Hash)

        acc[model.to_s] = rates.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end
    end

    private_class_method :resolve_promotional, :resolve_at, :normalize_overrides,
                         :resolve_key, :priced_total
  end
end

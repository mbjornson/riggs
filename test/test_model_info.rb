# test/test_model_info.rb
# frozen_string_literal: true

require "date"
require_relative "test_helper"

class TestModelInfo < Minitest::Test
  FIXTURE = {
    "test-model" => { input: 10.0, output: 30.0, cache_read: 1.0, cache_write: 12.0,
                      context_window: 200_000 }
  }.freeze

  # Promotional-overlay tests exercise the real TABLE rather than a fixture, because
  # `promotional:` blocks are (by design) a property of shipped entries. To avoid
  # asserting shipped price values, every value used below is read back out of the
  # table itself rather than hardcoded, and dates are derived from the promo's own
  # `until` rather than from Date.today.
  def promotional_model_and_entry
    model, entry = Riggs::ModelInfo::TABLE.find { |_, info| info[:promotional] }
    raise "No shipped TABLE entry has a promotional: block to test against" if model.nil?

    [model, entry]
  end

  def test_as_of_is_an_iso_date
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, Riggs::ModelInfo::AS_OF)
  end

  def test_shipped_table_entries_all_have_the_required_keys
    Riggs::ModelInfo::TABLE.each do |model, info|
      %i[input output context_window].each do |key|
        refute_nil info[key], "#{model} is missing #{key}"
      end
    end
  end

  def test_lookup_returns_nil_for_unknown_model
    assert_nil Riggs::ModelInfo.lookup("no-such-model")
  end

  def test_lookup_returns_nil_for_nil_model
    assert_nil Riggs::ModelInfo.lookup(nil)
  end

  def test_overrides_beat_the_shipped_table
    shipped = Riggs::ModelInfo::TABLE.keys.first
    overrides = { shipped => { input: 999.0 } }

    assert_equal 999.0, Riggs::ModelInfo.lookup(shipped, overrides: overrides)[:input]
  end

  def test_overrides_merge_rather_than_replace
    shipped = Riggs::ModelInfo::TABLE.keys.first
    expected_window = Riggs::ModelInfo::TABLE[shipped][:context_window]
    overrides = { shipped => { input: 999.0 } }

    assert_equal expected_window,
                 Riggs::ModelInfo.lookup(shipped, overrides: overrides)[:context_window]
  end

  def test_overrides_can_introduce_an_unknown_model
    info = Riggs::ModelInfo.lookup("self-hosted-llama", overrides: { "self-hosted-llama" => { input: 0.0, output: 0.0 } })

    assert_equal 0.0, info[:input]
  end

  def test_cost_sums_all_four_rates_per_million
    usage = { input_tokens: 1_000_000, output_tokens: 1_000_000,
              cache_read_tokens: 1_000_000, cache_write_tokens: 1_000_000, measured: true }

    cost = Riggs::ModelInfo.cost(model: "test-model", usage: usage, overrides: FIXTURE)

    assert_in_delta 53.0, cost, 0.0001 # 10 + 30 + 1 + 12
  end

  def test_cost_prorates_partial_millions
    usage = { input_tokens: 500_000, output_tokens: nil, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_in_delta 5.0, Riggs::ModelInfo.cost(model: "test-model", usage: usage, overrides: FIXTURE), 0.0001
  end

  def test_cost_is_nil_when_usage_is_unmeasured
    assert_nil Riggs::ModelInfo.cost(model: "test-model", usage: Riggs::Usage::EMPTY, overrides: FIXTURE)
  end

  def test_cost_is_nil_for_an_unpriced_model
    usage = { input_tokens: 100, output_tokens: 100, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_nil Riggs::ModelInfo.cost(model: "unpriced", usage: usage, overrides: FIXTURE)
  end

  def test_cost_is_nil_for_an_override_with_no_price_fields
    usage = { input_tokens: 1_000, output_tokens: 500, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }
    overrides = { "context-only-model" => { context_window: 50_000 } }

    assert_nil Riggs::ModelInfo.cost(model: "context-only-model", usage: usage, overrides: overrides)
  end

  def test_cost_is_nil_when_model_is_nil
    usage = { input_tokens: 100, output_tokens: 100, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_nil Riggs::ModelInfo.cost(model: nil, usage: usage, overrides: FIXTURE)
  end

  def test_context_window_reads_through_overrides
    assert_equal 200_000, Riggs::ModelInfo.context_window("test-model", overrides: FIXTURE)
    assert_nil Riggs::ModelInfo.context_window("unknown")
  end

  def test_promo_applies_before_its_until_date
    model, entry = promotional_model_and_entry
    until_date = Date.parse(entry[:promotional][:until])

    resolved = Riggs::ModelInfo.lookup(model, at: until_date - 1)

    assert_equal entry[:promotional][:input], resolved[:input]
  end

  def test_promo_applies_on_its_until_date_inclusive
    model, entry = promotional_model_and_entry
    until_date = Date.parse(entry[:promotional][:until])

    resolved = Riggs::ModelInfo.lookup(model, at: until_date)

    assert_equal entry[:promotional][:input], resolved[:input]
  end

  def test_promo_does_not_apply_after_its_until_date
    model, entry = promotional_model_and_entry
    until_date = Date.parse(entry[:promotional][:until])

    resolved = Riggs::ModelInfo.lookup(model, at: until_date + 1)

    assert_equal entry[:input], resolved[:input]
  end

  def test_entry_without_promotional_block_resolves_to_base_rates_at_any_date
    resolved = Riggs::ModelInfo.lookup("test-model", overrides: FIXTURE, at: Date.new(2099, 1, 1))

    assert_equal 10.0, resolved[:input]
  end

  def test_resolved_hash_never_contains_a_until_key
    model, entry = promotional_model_and_entry
    until_date = Date.parse(entry[:promotional][:until])

    during_promo = Riggs::ModelInfo.lookup(model, at: until_date)
    after_promo = Riggs::ModelInfo.lookup(model, at: until_date + 1)

    refute during_promo.key?(:until)
    refute after_promo.key?(:until)
  end

  def test_override_beats_a_live_promo
    model, entry = promotional_model_and_entry
    until_date = Date.parse(entry[:promotional][:until])
    overrides = { model => { input: 12_345.0 } }

    resolved = Riggs::ModelInfo.lookup(model, overrides: overrides, at: until_date)

    assert_equal 12_345.0, resolved[:input]
  end

  def test_cost_uses_promotional_rate_during_promo_and_standard_rate_after
    model, entry = promotional_model_and_entry
    until_date = Date.parse(entry[:promotional][:until])
    usage = { input_tokens: 1_000_000, output_tokens: 1_000_000, cache_read_tokens: 1_000_000,
              cache_write_tokens: 1_000_000, measured: true }

    promo_cost = Riggs::ModelInfo.cost(model: model, usage: usage, at: until_date)
    standard_cost = Riggs::ModelInfo.cost(model: model, usage: usage, at: until_date + 1)

    refute_equal promo_cost, standard_cost
    assert_operator standard_cost, :>, promo_cost
  end

  def test_at_accepts_an_iso_date_string
    model, entry = promotional_model_and_entry
    until_str = entry[:promotional][:until]

    by_string = Riggs::ModelInfo.lookup(model, at: until_str)
    by_date = Riggs::ModelInfo.lookup(model, at: Date.parse(until_str))

    assert_equal by_date, by_string
  end

  def test_at_defaults_to_today_when_omitted
    resolved = Riggs::ModelInfo.lookup("test-model", overrides: FIXTURE)

    assert_kind_of Hash, resolved
  end

  def test_shipped_promotional_entries_have_base_input_greater_than_promotional_input
    _, entry = promotional_model_and_entry

    assert_operator entry[:input], :>, entry[:promotional][:input]
  end

  # A provider default the table does not know reports no cost and no context
  # window on every call that does not override the model -- which is the
  # majority of calls. This cannot catch a model the VENDOR has retired (the
  # table has no retirement dates and the test makes no network call); it
  # catches a default drifting away from the priced set.
  def test_every_provider_default_model_is_priced_by_the_table
    [Riggs::Providers::Anthropic::DEFAULT_MODEL,
     Riggs::Providers::OpenAICompatible::DEFAULT_MODEL].each do |model|
      assert_includes Riggs::ModelInfo::TABLE.keys, model,
                      "#{model} is a shipped provider default and must carry a price and context window"
    end
  end

  # Providers report the model the API actually served, which for OpenAI is a
  # dated build ID no shipped table can enumerate. Exact-match-only lookup made
  # every real call unpriced while the undated alias in the table priced fine.
  def test_a_dated_model_id_prices_as_its_base_model
    usage = { input_tokens: 1000, output_tokens: 500, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_in_delta Riggs::ModelInfo.cost(model: "gpt-4o-mini", usage: usage),
                    Riggs::ModelInfo.cost(model: "gpt-4o-mini-2024-07-18", usage: usage)
  end

  def test_a_dated_model_id_resolves_the_longest_matching_key
    # "claude-opus-4-6" and "claude-opus-4-8" both exist; a dated 4-6 build must
    # not fall back to some shorter prefix that happens to also match.
    assert_equal Riggs::ModelInfo.context_window("claude-opus-4-6"),
                 Riggs::ModelInfo.context_window("claude-opus-4-6-20260301")
  end

  def test_a_dated_model_id_reads_an_override_for_its_base_model
    overrides = { "test-model" => { input: 2.0 } }
    usage = { input_tokens: 1_000_000, output_tokens: nil, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_in_delta 2.0, Riggs::ModelInfo.cost(model: "test-model-20260101", usage: usage, overrides: overrides)
  end

  def test_an_unrelated_model_sharing_a_prefix_is_not_matched
    # "gpt-4o-mini" must not answer for "gpt-4o-miniature" -- a different family
    # that merely shares a prefix.
    assert_nil Riggs::ModelInfo.lookup("gpt-4o-miniature")
  end

  # Accepting base + "-" + ANYTHING was too loose: a differently-priced variant
  # (`-realtime`, `-audio`, a vendor's next suffix convention) would silently
  # price at the base model's rate. Only a dated build resolves; anything else
  # is unpriced, which reports nil rather than a confident wrong number.
  def test_a_non_dated_variant_does_not_borrow_the_base_price
    assert_nil Riggs::ModelInfo.lookup("gpt-4o-mini-not-a-date")
    assert_nil Riggs::ModelInfo.lookup("gpt-4o-mini-realtime")
  end

  def test_both_shipped_date_suffix_conventions_resolve
    # OpenAI writes 2024-07-18; Anthropic writes 20250805.
    refute_nil Riggs::ModelInfo.lookup("gpt-4o-mini-2024-07-18")
    refute_nil Riggs::ModelInfo.lookup("claude-opus-4-6-20260301")
  end

  # The invariant is "unpriced is nil, never 0". A model priced for output but
  # not input reported 0.0 for an input-only call: a confident zero for tokens
  # that were measured, billed, and unpriceable.
  def test_cost_is_nil_when_a_reported_category_has_no_rate
    usage = { input_tokens: 10, output_tokens: nil, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_nil Riggs::ModelInfo.cost(model: "half", usage: usage,
                                     overrides: { "half" => { input: nil, output: 1.0 } })
  end

  # The converse must keep working: OpenAI has no cache-write price at all, and
  # every OpenAI call reports zero cache writes. Zero unpriceable tokens cost
  # nothing knowable, so they must not nil out an otherwise priceable call.
  def test_a_zero_token_category_with_no_rate_does_not_nil_the_cost
    usage = { input_tokens: 1000, output_tokens: 500, cache_read_tokens: nil,
              cache_write_tokens: 0, measured: true }

    refute_nil Riggs::ModelInfo.cost(model: "gpt-4o-mini", usage: usage)
  end
end

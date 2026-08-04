# test/test_model_info.rb
# frozen_string_literal: true

require_relative "test_helper"

class TestModelInfo < Minitest::Test
  FIXTURE = {
    "test-model" => { input: 10.0, output: 30.0, cache_read: 1.0, cache_write: 12.0,
                      context_window: 200_000 }
  }.freeze

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
end

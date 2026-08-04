# frozen_string_literal: true

require_relative "test_helper"

class TestStorageUsage < Minitest::Test
  MEASURED = { input_tokens: 100, output_tokens: 50, cache_read_tokens: 20,
               cache_write_tokens: 10, total_tokens: 180, measured: true }.freeze

  def setup
    @dir = Dir.mktmpdir("riggs-storage-usage")
    @storage = Riggs::Storage.new(db_path: File.join(@dir, "db", "riggs.sqlite3"))
    @session_id = @storage.create_session(
      workflow_name: "example_triage", user_id: "eng_bob", memory_namespace: "ns"
    )
  end

  def teardown
    @storage.close
    FileUtils.remove_entry(@dir)
  end

  def record(step_key: "triage", usage: MEASURED, cost_usd: 0.25, provider: "anthropic",
             model: "test-model", relay_attempt: 1)
    @storage.record_provider_call(
      session_id: @session_id, step_key: step_key, provider: provider, model: model,
      relay_attempt: relay_attempt, usage: usage, cost_usd: cost_usd
    )
  end

  def test_records_a_measured_call
    record

    row = @storage.db.get_first_row("SELECT * FROM riggs_provider_calls WHERE session_id = ?", [@session_id])

    assert_equal 100, row["input_tokens"]
    assert_equal 1, row["measured"]
    assert_in_delta 0.25, row["cost_usd"], 0.0001
    assert_equal "anthropic", row["provider"]
  end

  # NULL, not 0. A zero is indistinguishable from a genuinely empty call.
  def test_unmeasured_call_stores_nulls_not_zeros
    record(usage: Riggs::Usage::EMPTY, cost_usd: nil)

    row = @storage.db.get_first_row("SELECT * FROM riggs_provider_calls WHERE session_id = ?", [@session_id])

    assert_nil row["input_tokens"]
    assert_nil row["cost_usd"]
    assert_equal 0, row["measured"]
  end

  def test_session_usage_sums_measured_calls_only
    record
    record
    record(usage: Riggs::Usage::EMPTY, cost_usd: nil)

    totals = @storage.session_usage(@session_id)

    assert_equal 200, totals[:input_tokens]
    assert_equal 360, totals[:total_tokens]
    assert_equal 3, totals[:calls]
    assert_equal 2, totals[:measured_calls]
  end

  def test_session_usage_counts_measured_and_priced_independently
    record                                  # measured + priced
    record(cost_usd: nil)                   # measured, unpriced
    record(usage: Riggs::Usage::EMPTY, cost_usd: nil) # neither

    totals = @storage.session_usage(@session_id)

    assert_equal 3, totals[:calls]
    assert_equal 2, totals[:measured_calls]
    assert_equal 1, totals[:priced_calls]
  end

  def test_session_usage_on_an_empty_session_reports_zero_calls_and_nil_totals
    totals = @storage.session_usage(@session_id)

    assert_equal 0, totals[:calls]
    assert_nil totals[:total_tokens]
    assert_nil totals[:cost_usd]
  end

  def test_step_usage_groups_by_step_key
    record(step_key: "triage")
    record(step_key: "triage")
    record(step_key: "draft")

    rows = @storage.step_usage(@session_id)

    assert_equal 2, rows.length
    triage = rows.find { |r| r[:step_key] == "triage" }

    assert_equal 2, triage[:calls]
    assert_equal 200, triage[:input_tokens]
  end

  def test_relay_attempt_records_the_answering_attempt
    record(provider: "openai", relay_attempt: 2)

    row = @storage.db.get_first_row("SELECT * FROM riggs_provider_calls WHERE session_id = ?", [@session_id])

    assert_equal 2, row["relay_attempt"]
    assert_equal "openai", row["provider"]
  end
end

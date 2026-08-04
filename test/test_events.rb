# frozen_string_literal: true

require "test_helper"
require "json"

class TestEvents < Minitest::Test
  def audit_row(overrides = {})
    {
      "id" => 7,
      "session_id" => "sess-1",
      "event_type" => "step_start",
      "payload" => JSON.generate({ "step" => "triage" }),
      "created_at" => "2026-08-04 10:00:00"
    }.merge(overrides)
  end

  def test_normalize_maps_a_well_formed_row
    event = Riggs::Events.normalize(audit_row)

    assert_equal 7, event[:id]
    assert_equal "step_start", event[:type]
    assert_equal "sess-1", event[:session_id]
    assert_equal "2026-08-04 10:00:00", event[:at]
    assert_equal({ "step" => "triage" }, event[:payload])
  end

  def test_normalize_malformed_payload_becomes_raw
    event = Riggs::Events.normalize(audit_row("payload" => "{not json"))

    assert_equal({ "raw" => "{not json" }, event[:payload])
  end

  def test_normalize_non_object_payload_becomes_raw
    event = Riggs::Events.normalize(audit_row("payload" => "42"))

    assert_equal({ "raw" => "42" }, event[:payload])
  end

  def test_normalize_blank_payload_is_an_empty_hash
    assert_empty Riggs::Events.normalize(audit_row("payload" => nil))[:payload]
    assert_empty Riggs::Events.normalize(audit_row("payload" => ""))[:payload]
  end

  # list_audit_after does not select session_id, so callers supply it.
  def test_normalize_falls_back_to_the_session_id_argument
    row = audit_row
    row.delete("session_id")

    assert_equal "sess-2", Riggs::Events.normalize(row, session_id: "sess-2")[:session_id]
    assert_equal "sess-1", Riggs::Events.normalize(audit_row, session_id: "sess-2")[:session_id]
  end

  def test_to_jsonl_is_one_line_of_json_with_no_trailing_newline
    line = Riggs::Events.to_jsonl(audit_row)

    refute_includes line, "\n"
    assert_equal JSON.parse(JSON.generate(Riggs::Events.normalize(audit_row))), JSON.parse(line)
  end

  def test_clamp_limit_defaults_and_bounds
    assert_equal 500, Riggs::Events.clamp_limit(nil)
    assert_equal 500, Riggs::Events.clamp_limit("")
    assert_equal 25, Riggs::Events.clamp_limit("25")
    assert_equal 1000, Riggs::Events.clamp_limit("5000")
    assert_equal 1, Riggs::Events.clamp_limit("0")
    assert_equal 1, Riggs::Events.clamp_limit("-7")
    assert_equal 1, Riggs::Events.clamp_limit("abc")
  end

  def test_terminal_status_predicate
    %w[completed failed rejected].each { |s| assert Riggs::Events.terminal?(s), "#{s} should be terminal" }
    %w[running paused awaiting_approval approved_pending_resume].each do |s|
      refute Riggs::Events.terminal?(s), "#{s} should not be terminal"
    end
  end
end

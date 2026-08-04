# frozen_string_literal: true

require_relative "test_helper"

class TestStorageAuditPaging < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("riggs-storage-audit")
    @storage = Riggs::Storage.new(db_path: File.join(@dir, "db", "riggs.sqlite3"))
    @session_id = @storage.create_session(
      workflow_name: "example_triage", user_id: "eng_bob", memory_namespace: "ns"
    )
    5.times { |i| @storage.audit(session_id: @session_id, event_type: "step_executed", payload: { n: i }) }
  end

  def teardown
    @storage.close
    FileUtils.remove_entry(@dir)
  end

  def test_list_audit_after_returns_only_newer_rows_ascending
    all = @storage.list_audit(@session_id)
    cutoff = all[1]["id"]

    rows = @storage.list_audit_after(@session_id, cutoff)

    assert_equal 3, rows.length
    assert(rows.all? { |r| r["id"] > cutoff })
    assert_equal rows.map { |r| r["id"] }.sort, rows.map { |r| r["id"] }
  end

  def test_list_audit_after_rows_carry_their_session_id
    row = @storage.list_audit_after(@session_id, 0).first

    assert_equal @session_id, row["session_id"]
  end

  def test_list_audit_after_zero_returns_everything
    assert_equal 5, @storage.list_audit_after(@session_id, 0).length
  end

  def test_list_audit_after_honours_limit
    assert_equal 2, @storage.list_audit_after(@session_id, 0, limit: 2).length
  end

  def test_list_audit_after_scopes_to_session
    other = @storage.create_session(workflow_name: "w", user_id: "u", memory_namespace: "n")
    @storage.audit(session_id: other, event_type: "workflow_start", payload: {})

    rows = @storage.list_audit_after(@session_id, 0)

    assert_equal 5, rows.length
  end
end

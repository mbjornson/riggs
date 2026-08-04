# frozen_string_literal: true

require_relative "test_helper"

class TestStorageMessages < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("riggs-storage")
    @storage = Riggs::Storage.new(db_path: File.join(@dir, "db", "riggs.sqlite3"))
    @session_id = @storage.create_session(
      workflow_name: "example_triage",
      user_id: "eng_bob",
      memory_namespace: "eng_bob_private"
    )
  end

  def teardown
    @storage.close
    FileUtils.remove_entry(@dir)
  end

  def test_append_message_allocates_gapless_seq_starting_at_one
    @storage.append_message(session_id: @session_id, step_key: "classify", role: "user", content: "hello")
    @storage.append_message(session_id: @session_id, step_key: "classify", role: "assistant", content: "hi")

    rows = @storage.list_messages(@session_id)

    assert_equal [1, 2], rows.map { |r| r["seq"] }
    assert_equal %w[user assistant], rows.map { |r| r["role"] }
    assert_equal %w[hello hi], rows.map { |r| r["content"] }
  end

  def test_next_message_seq_is_one_on_empty_session
    assert_equal 1, @storage.next_message_seq(@session_id)
  end

  def test_next_message_seq_advances_past_existing_rows
    @storage.append_message(session_id: @session_id, step_key: "classify", role: "user", content: "hello")

    assert_equal 2, @storage.next_message_seq(@session_id)
  end

  def test_list_messages_filters_by_step_key
    @storage.append_message(session_id: @session_id, step_key: "classify", role: "user", content: "a")
    @storage.append_message(session_id: @session_id, step_key: "respond", role: "user", content: "b")

    rows = @storage.list_messages(@session_id, step_key: "respond")

    assert_equal ["b"], rows.map { |r| r["content"] }
  end

  def test_append_message_round_trips_tool_fields
    @storage.append_message(
      session_id: @session_id, step_key: "classify", role: "assistant", content: "",
      tool_calls: [{ id: "t1", name: "lookup_runbook", arguments: { topic: "auth" } }], provider: "anthropic"
    )
    @storage.append_message(
      session_id: @session_id, step_key: "classify", role: "tool", content: "Runbook[auth]",
      tool_call_id: "t1", tool_name: "lookup_runbook"
    )

    assistant, tool = @storage.list_messages(@session_id)

    assert_equal "anthropic", assistant["provider"]
    assert_equal "lookup_runbook", JSON.parse(assistant["tool_calls"]).first["name"]
    assert_equal "t1", tool["tool_call_id"]
    assert_equal "lookup_runbook", tool["tool_name"]
  end

  def test_explicit_seq_is_honoured
    @storage.append_message(session_id: @session_id, step_key: "classify", role: "user", content: "a", seq: 7)

    assert_equal 7, @storage.list_messages(@session_id).first["seq"]
    assert_equal 8, @storage.next_message_seq(@session_id)
  end

  def test_duplicate_explicit_seq_is_rejected
    @storage.append_message(session_id: @session_id, step_key: "classify", role: "user", content: "a", seq: 3)

    assert_raises(SQLite3::ConstraintException) do
      @storage.append_message(session_id: @session_id, step_key: "classify", role: "assistant", content: "b", seq: 3)
    end
  end

  def test_same_seq_in_a_different_session_is_allowed
    other = @storage.create_session(workflow_name: "w", user_id: "u", memory_namespace: "n")
    @storage.append_message(session_id: @session_id, step_key: "classify", role: "user", content: "a", seq: 3)
    @storage.append_message(session_id: other, step_key: "classify", role: "user", content: "b", seq: 3)

    assert_equal 3, @storage.list_messages(other).first["seq"]
  end

  def test_claim_paused_session_succeeds_once_and_only_once
    @storage.update_session(@session_id, status: "paused")

    assert @storage.claim_paused_session(@session_id), "the first claim must win"
    refute @storage.claim_paused_session(@session_id), "a second claim must lose the race"
    assert_equal "running", @storage.find_session(@session_id)["status"]
  end

  def test_claim_paused_session_refuses_a_session_that_is_not_paused
    @storage.update_session(@session_id, status: "completed")

    refute @storage.claim_paused_session(@session_id)
    assert_equal "completed", @storage.find_session(@session_id)["status"]
  end

  def test_resume_state_round_trips_with_symbol_keys
    @storage.save_resume_state(@session_id, { current_step_id: "respond", llm_calls: 3, outputs: { a: "b" } })

    state = @storage.load_resume_state(@session_id)

    assert_equal "respond", state[:current_step_id]
    assert_equal 3, state[:llm_calls]
    assert_equal({ a: "b" }, state[:outputs])
  end

  def test_load_resume_state_is_nil_when_unset
    assert_nil @storage.load_resume_state(@session_id)
  end

  def test_save_resume_state_nil_clears_it
    @storage.save_resume_state(@session_id, { current_step_id: "respond" })
    @storage.save_resume_state(@session_id, nil)

    assert_nil @storage.load_resume_state(@session_id)
  end
end

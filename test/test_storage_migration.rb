# frozen_string_literal: true

require_relative "test_helper"

# CI and every other test build the database from scratch, so the schema is
# always current and Storage#ensure_columns! never actually runs its ALTER.
# The real risk is a database that predates Phase 6: it has riggs_sessions
# without resume_state and no riggs_messages table at all. These tests seed
# exactly that shape with raw SQLite3 and then open it with Storage.
class TestStorageMigration < Minitest::Test
  # The riggs_sessions/riggs_steps/riggs_audit shape as it stood before
  # resume_state and riggs_messages were introduced. Written out by hand on
  # purpose: it must NOT track db/init_riggs_schema.sql.
  PRE_PHASE_6_SCHEMA = <<~SQL
    CREATE TABLE riggs_sessions (
      id TEXT PRIMARY KEY,
      workflow_name TEXT NOT NULL,
      user_id TEXT NOT NULL,
      status TEXT DEFAULT 'running',
      started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      ended_at DATETIME,
      memory_namespace TEXT,
      config_snapshot TEXT
    );
    CREATE TABLE riggs_steps (
      id TEXT PRIMARY KEY,
      session_id TEXT REFERENCES riggs_sessions(id),
      step_key TEXT NOT NULL,
      label TEXT,
      status TEXT DEFAULT 'pending',
      input_preview TEXT,
      output_var_name TEXT,
      executed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      gate_decided_at DATETIME
    );
    CREATE TABLE riggs_audit (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT REFERENCES riggs_sessions(id),
      event_type TEXT,
      payload TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    CREATE INDEX idx_riggs_steps_session ON riggs_steps(session_id);
    CREATE INDEX idx_riggs_audit_session ON riggs_audit(session_id);
  SQL

  LEGACY_SESSION_ID = "11111111-2222-3333-4444-555555555555"

  def setup
    @dir = Dir.mktmpdir("riggs-storage-migration")
    @db_path = File.join(@dir, "db", "riggs.sqlite3")
    @storages = []
    seed_legacy_database
  end

  def teardown
    @storages.each(&:close)
    FileUtils.remove_entry(@dir)
  end

  # Guards the guard: if this ever fails the fixture drifted into being
  # current-schema and every other test in this file would pass vacuously.
  def test_fixture_really_predates_the_migration
    refute_includes raw_columns("riggs_sessions"), "resume_state"
    refute_includes raw_tables, "riggs_messages"
  end

  def test_opening_a_legacy_database_adds_the_resume_state_column
    open_storage

    assert_includes raw_columns("riggs_sessions"), "resume_state"
  end

  def test_migrated_resume_state_column_round_trips_through_storage
    storage = open_storage

    storage.save_resume_state(LEGACY_SESSION_ID, { current_step_id: "respond", llm_calls: 2 })

    assert_equal "respond", storage.load_resume_state(LEGACY_SESSION_ID)[:current_step_id]
    assert_equal 2, storage.load_resume_state(LEGACY_SESSION_ID)[:llm_calls]
  end

  def test_opening_a_legacy_database_creates_the_messages_table
    storage = open_storage

    storage.append_message(session_id: LEGACY_SESSION_ID, step_key: "classify", role: "user", content: "hello")

    assert_includes raw_tables, "riggs_messages"
    assert_equal ["hello"], storage.list_messages(LEGACY_SESSION_ID).map { |r| r["content"] }
  end

  def test_migration_preserves_existing_rows
    storage = open_storage

    row = storage.find_session(LEGACY_SESSION_ID)

    assert_equal "example_triage", row["workflow_name"]
    assert_equal "eng_bob", row["user_id"]
    assert_nil row["resume_state"]
  end

  def test_reopening_a_migrated_database_is_idempotent
    first = open_storage
    first.save_resume_state(LEGACY_SESSION_ID, { current_step_id: "respond" })

    second = open_storage # must not raise "duplicate column name: resume_state"

    assert_equal 1, raw_columns("riggs_sessions").count("resume_state")
    assert_equal "respond", second.load_resume_state(LEGACY_SESSION_ID)[:current_step_id]
  end

  def test_reopening_an_already_current_database_is_idempotent
    3.times { open_storage }

    assert_equal 1, raw_columns("riggs_sessions").count("resume_state")
  end

  private

  def open_storage
    storage = Riggs::Storage.new(db_path: @db_path)
    @storages << storage
    storage
  end

  def seed_legacy_database
    FileUtils.mkdir_p(File.dirname(@db_path))
    with_raw_db do |db|
      PRE_PHASE_6_SCHEMA.split(";").map(&:strip).reject(&:empty?).each { |stmt| db.execute(stmt) }
      db.execute(
        "INSERT INTO riggs_sessions (id, workflow_name, user_id, status, memory_namespace, config_snapshot) " \
        "VALUES (?, ?, ?, ?, ?, ?)",
        [LEGACY_SESSION_ID, "example_triage", "eng_bob", "paused", "eng_bob_private", "{}"]
      )
    end
  end

  def raw_columns(table)
    with_raw_db { |db| db.execute("PRAGMA table_info(#{table})").map { |r| r["name"] } }
  end

  def raw_tables
    with_raw_db { |db| db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map { |r| r["name"] } }
  end

  # Deliberately bypasses Storage so inspection never triggers a migration.
  def with_raw_db
    db = SQLite3::Database.new(@db_path)
    db.results_as_hash = true
    yield db
  ensure
    db&.close
  end
end

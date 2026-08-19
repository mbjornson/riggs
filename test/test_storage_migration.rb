# frozen_string_literal: true

require_relative "test_helper"

# CI and every other test build the database from scratch, so the schema is
# always current and Storage#ensure_columns! never actually runs its ALTER.
# The real risk is a database that predates a later column: CREATE TABLE IF
# NOT EXISTS leaves the old table untouched. These tests seed that shape with
# raw SQLite3 and then open it with Storage.
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
    refute_includes raw_columns("riggs_sessions"), "project_path"
    refute_includes raw_tables, "riggs_messages"
    refute_includes raw_tables, "riggs_provider_calls"
  end

  def test_opening_a_legacy_database_adds_the_resume_state_column
    open_storage

    assert_includes raw_columns("riggs_sessions"), "resume_state"
  end

  # Second column on the same table, so the migration must add BOTH rather than
  # stopping at the first absent one.
  def test_opening_a_legacy_database_adds_the_project_path_column
    open_storage

    assert_includes raw_columns("riggs_sessions"), "project_path"
  end

  # Rows written before the column exists are NULL, not blank. Both roll-ups
  # bucket them as (unattributed), which only works if they stay distinguishable
  # from a row that genuinely recorded an empty path.
  def test_rows_that_predate_the_column_stay_null
    storage = open_storage

    assert_nil storage.find_session(LEGACY_SESSION_ID)["project_path"]
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

  def test_opening_a_legacy_database_creates_the_provider_calls_table
    Riggs::Storage.new(db_path: @db_path).close

    assert_includes raw_tables, "riggs_provider_calls"
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

  # steps/audit never gained columns after first ship, so this fixture is a
  # current-schema table with one ALTER-safe column stripped. CREATE TABLE IF
  # NOT EXISTS will not add it; ensure_columns! must.
  def test_opening_a_stripped_memories_table_adds_missing_columns
    with_raw_db do |db|
      db.execute(<<~SQL)
        CREATE TABLE riggs_memories (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          namespace TEXT NOT NULL,
          content TEXT NOT NULL
        )
      SQL
      db.execute("INSERT INTO riggs_memories (namespace, content) VALUES (?, ?)", %w[eng_bob_private old-note])
    end

    refute_includes raw_columns("riggs_memories"), "context"

    open_storage

    assert_includes raw_columns("riggs_memories"), "context"
    row = with_raw_db { |db| db.get_first_row("SELECT namespace, content, context FROM riggs_memories") }

    assert_equal "eng_bob_private", row["namespace"]
    assert_equal "old-note", row["content"]
    assert_nil row["context"]
  end

  # riggs_sessions is declared TWICE: in db/init_riggs_schema.sql, which
  # Storage#schema_sql reads when it is reachable, and in the embedded fallback
  # heredoc it uses when the gem layout puts that file out of reach. Nothing
  # made them agree, so a column added to one and not the other exists in
  # development and is absent in a packaged gem -- with no failure until
  # something selects it. Compared as declared column names because that is the
  # part a migration depends on.
  def test_both_declarations_of_riggs_sessions_agree
    assert_equal declared_columns(File.read(SCHEMA_FILE)),
                 declared_columns(File.read(STORAGE_SOURCE)),
                 "db/init_riggs_schema.sql and Storage's embedded fallback have drifted"
  end

  SCHEMA_FILE = File.expand_path("../db/init_riggs_schema.sql", __dir__)
  STORAGE_SOURCE = File.expand_path("../lib/riggs/storage.rb", __dir__)

  private

  # Reads the source text on purpose: the invariant being guarded is that two
  # textual declarations say the same thing, and only one of them is reachable
  # through the API at a time.
  def declared_columns(source)
    body = source[/CREATE TABLE IF NOT EXISTS riggs_sessions \((.*?)\);/m, 1]
    refute_nil body, "no riggs_sessions declaration found"
    body.lines.map { |line| line.strip.split(/\s+/).first }.compact.reject(&:empty?)
  end

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

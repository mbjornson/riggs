# frozen_string_literal: true

require "sqlite3"
require "json"
require "securerandom"
require "fileutils"

module Riggs
  class Storage
    attr_reader :db_path, :db

    def initialize(db_path:)
      @db_path = db_path
      FileUtils.mkdir_p(File.dirname(db_path))
      @db = SQLite3::Database.new(db_path)
      @db.results_as_hash = true
      @db.execute("PRAGMA foreign_keys = ON")
      ensure_schema!
      ensure_columns!
    end

    # CREATE TABLE IF NOT EXISTS never alters a table that already exists, so
    # columns added after a database is in the field need an explicit backfill.
    def ensure_columns!
      cols = @db.execute("PRAGMA table_info(riggs_sessions)").map { |r| r["name"] }
      @db.execute("ALTER TABLE riggs_sessions ADD COLUMN resume_state TEXT") unless cols.include?("resume_state")
    end

    def ensure_schema!
      schema = schema_sql
      if @db.respond_to?(:execute_batch)
        @db.execute_batch(schema)
      else
        # Fallback: split only on semicolons that terminate statements at depth 0
        buffer = +""
        depth = 0
        schema.each_line do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("--")

          depth += stripped.scan(/\bBEGIN\b/i).size
          depth -= stripped.scan(/\bEND\b/i).size
          buffer << line
          next unless depth <= 0 && stripped.end_with?(";")

          @db.execute(buffer.strip)
          buffer = +""
          depth = 0
        end
        @db.execute(buffer.strip) unless buffer.strip.empty?
      end
    end

    def create_session(workflow_name:, user_id:, memory_namespace:, config_snapshot: {})
      id = SecureRandom.uuid
      @db.execute(
        "INSERT INTO riggs_sessions (id, workflow_name, user_id, status, memory_namespace, config_snapshot) " \
        "VALUES (?, ?, ?, ?, ?, ?)",
        [id, workflow_name, user_id, "running", memory_namespace, JSON.generate(config_snapshot)]
      )
      id
    end

    def update_session(session_id, status:, ended: false)
      sid = utf8(session_id)
      if ended
        @db.execute(
          "UPDATE riggs_sessions SET status = ?, ended_at = CURRENT_TIMESTAMP WHERE id = ?",
          [status, sid]
        )
      else
        @db.execute("UPDATE riggs_sessions SET status = ? WHERE id = ?", [status, sid])
      end
    end

    def create_step(session_id:, step_key:, label:, status: "pending", input_preview: nil, output_var_name: nil)
      id = SecureRandom.uuid
      @db.execute(
        "INSERT INTO riggs_steps (id, session_id, step_key, label, status, input_preview, output_var_name) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [id, utf8(session_id), step_key, label, status, input_preview, output_var_name]
      )
      id
    end

    def update_step(step_id, status:, gate_decided: false)
      sid = utf8(step_id)
      if gate_decided
        @db.execute(
          "UPDATE riggs_steps SET status = ?, gate_decided_at = CURRENT_TIMESTAMP, executed_at = CURRENT_TIMESTAMP WHERE id = ?",
          [status, sid]
        )
      else
        @db.execute(
          "UPDATE riggs_steps SET status = ?, executed_at = CURRENT_TIMESTAMP WHERE id = ?",
          [status, sid]
        )
      end
    end

    # Persists one conversation turn. When seq is omitted it is allocated inside
    # the insert itself, so concurrent writers cannot collide on the same value.
    def append_message(session_id:, step_key:, role:, content: nil, seq: nil,
                       tool_call_id: nil, tool_name: nil, tool_calls: nil, provider: nil)
      sid = utf8(session_id)
      @db.execute(
        "INSERT INTO riggs_messages " \
        "(session_id, step_key, seq, role, content, tool_call_id, tool_name, tool_calls, provider) " \
        "VALUES (?, ?, COALESCE(?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM riggs_messages WHERE session_id = ?)), " \
        "?, ?, ?, ?, ?, ?)",
        [sid, step_key.to_s, seq, sid, role.to_s, content&.to_s, tool_call_id&.to_s, tool_name&.to_s,
         tool_calls.nil? ? nil : JSON.generate(tool_calls), provider&.to_s]
      )
      @db.last_insert_row_id
    end

    def list_messages(session_id, step_key: nil)
      if step_key
        @db.execute(
          "SELECT * FROM riggs_messages WHERE session_id = ? AND step_key = ? ORDER BY seq ASC",
          [utf8(session_id), step_key.to_s]
        )
      else
        @db.execute("SELECT * FROM riggs_messages WHERE session_id = ? ORDER BY seq ASC", [utf8(session_id)])
      end
    end

    def next_message_seq(session_id)
      row = @db.get_first_row(
        "SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM riggs_messages WHERE session_id = ?",
        [utf8(session_id)]
      )
      row ? row["next"].to_i : 1
    end

    # Atomically claims a paused run for resumption. The status check and the
    # write are one statement, so two concurrent resumers cannot both win and
    # execute the gated step twice. Returns true only for the winner.
    def claim_paused_session(session_id)
      @db.execute(
        "UPDATE riggs_sessions SET status = 'running' WHERE id = ? AND status = 'paused'",
        [utf8(session_id)]
      )
      @db.changes.positive?
    end

    # state: Hash to store, or nil to clear once a run is no longer resumable.
    def save_resume_state(session_id, state)
      @db.execute(
        "UPDATE riggs_sessions SET resume_state = ? WHERE id = ?",
        [state.nil? ? nil : JSON.generate(state), utf8(session_id)]
      )
    end

    def load_resume_state(session_id)
      row = @db.get_first_row("SELECT resume_state FROM riggs_sessions WHERE id = ?", [utf8(session_id)])
      raw = row && row["resume_state"]
      return nil if raw.nil? || raw.to_s.empty?

      deep_symbolize(JSON.parse(raw))
    rescue JSON::ParserError
      nil
    end

    def list_audit_after(session_id, after_id, limit: 500)
      @db.execute(
        "SELECT id, session_id, event_type, payload, created_at FROM riggs_audit " \
        "WHERE session_id = ? AND id > ? ORDER BY id ASC LIMIT ?",
        [utf8(session_id), after_id.to_i, limit.to_i]
      )
    end

    def audit(session_id:, event_type:, payload: {})
      @db.execute(
        "INSERT INTO riggs_audit (session_id, event_type, payload) VALUES (?, ?, ?)",
        [utf8(session_id), event_type, JSON.generate(payload)]
      )
    end

    def list_audit(session_id)
      @db.execute(
        "SELECT id, event_type, payload, created_at FROM riggs_audit WHERE session_id = ? ORDER BY id ASC",
        [utf8(session_id)]
      )
    end

    def find_session(session_id)
      @db.get_first_row("SELECT * FROM riggs_sessions WHERE id = ?", [utf8(session_id)])
    end

    def close
      @db&.close
    end

    # Rack path captures are often ASCII-8BIT; sqlite3 binds those as BLOBs.
    def self.utf8(value)
      str = value.to_s
      str = str.dup if str.frozen?
      str.force_encoding(Encoding::UTF_8)
      str.valid_encoding? ? str : str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def utf8(value)
      self.class.utf8(value)
    end

    private

    # Local copy rather than Riggs::Identity.deep_symbolize so Storage stays
    # loadable on its own.
    def deep_symbolize(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      when Array then value.map { |v| deep_symbolize(v) }
      else value
      end
    end

    def schema_sql
      path = File.expand_path("../../db/init_riggs_schema.sql", __dir__)
      if File.exist?(path)
        File.read(path)
      else
        # Fallback embedded schema when gem layout differs
        <<~SQL
          PRAGMA journal_mode=WAL;
          CREATE TABLE IF NOT EXISTS riggs_sessions (
            id TEXT PRIMARY KEY,
            workflow_name TEXT NOT NULL,
            user_id TEXT NOT NULL,
            status TEXT DEFAULT 'running',
            started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            ended_at DATETIME,
            memory_namespace TEXT,
            config_snapshot TEXT
          );
          CREATE TABLE IF NOT EXISTS riggs_steps (
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
          CREATE TABLE IF NOT EXISTS riggs_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES riggs_sessions(id),
            step_key TEXT NOT NULL,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT,
            tool_call_id TEXT,
            tool_name TEXT,
            tool_calls TEXT,
            provider TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
          );
          DROP INDEX IF EXISTS idx_riggs_messages_session;
          CREATE UNIQUE INDEX IF NOT EXISTS idx_riggs_messages_session_seq ON riggs_messages(session_id, seq);
          CREATE TABLE IF NOT EXISTS riggs_audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT REFERENCES riggs_sessions(id),
            event_type TEXT,
            payload TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
          );
          CREATE TABLE IF NOT EXISTS riggs_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            namespace TEXT NOT NULL,
            content TEXT NOT NULL,
            context TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
          );
          CREATE VIRTUAL TABLE IF NOT EXISTS riggs_memories_fts USING fts5(
            content,
            content='riggs_memories',
            content_rowid='id'
          );
        SQL
      end
    end
  end
end

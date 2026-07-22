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

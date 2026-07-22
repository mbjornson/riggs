# frozen_string_literal: true

require "sqlite3"
require "json"

module Riggs
  class MemoryService
    attr_reader :namespace, :db_path, :backend

    def initialize(namespace:, db_path:, config: {})
      @namespace = namespace.to_s
      @db_path = db_path
      @config = config || {}
      @conn = SQLite3::Database.new(db_path)
      @conn.results_as_hash = true
      @warned = false
      @backend = load_extensions!
      ensure_fallback_schema! if @backend == :fts
    end

    def persist(text, context: "general")
      return false if text.nil? || text.to_s.strip.empty?

      case @backend
      when :sqlite_memory
        scope = "#{context}_by_#{@namespace}"
        @conn.execute("SELECT memory_add_text(?, ?)", [text.to_s, scope])
      else
        @conn.execute(
          "INSERT INTO riggs_memories (namespace, content, context) VALUES (?, ?, ?)",
          [@namespace, text.to_s, context.to_s]
        )
      end
      true
    end

    def recall(query, min_score: 0.7, limit: 5)
      return [] if query.nil? || query.to_s.strip.empty?

      case @backend
      when :sqlite_memory
        recall_sqlite_memory(query, min_score: min_score, limit: limit)
      else
        recall_fts(query, limit: limit)
      end
    end

    def close
      @conn&.close
    end

    private

    def load_extensions!
      vector_path = ext_path(:vector_path, "RIGGS_VECTOR_EXT")
      memory_path = ext_path(:memory_path, "RIGGS_MEMORY_EXT")

      return :fts if vector_path.nil? || memory_path.nil? || !File.exist?(vector_path) || !File.exist?(memory_path)

      @conn.enable_load_extension(true)
      @conn.load_extension(vector_path)
      @conn.load_extension(memory_path)

      model = @config[:embed_model] || ENV.fetch("RIGGS_EMBED_MODEL", nil)
      if model && File.exist?(model)
        @conn.execute("SELECT memory_set_model('local', ?)", [model])
      elsif ENV["VECTORS_SPACE_API_KEY"]
        @conn.execute("SELECT memory_set_model('remote', ?)", [ENV["VECTORS_SPACE_API_KEY"]])
      end

      :sqlite_memory
    rescue StandardError => e
      warn_once("sqlite-memory extension not loaded (#{e.message}); using FTS5 fallback.")
      :fts
    end

    def ext_path(key, env_key)
      from_cfg = @config[key] || @config[key.to_s]
      from_cfg || ENV.fetch(env_key, nil)
    end

    def ensure_fallback_schema!
      @conn.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS riggs_memories (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          namespace TEXT NOT NULL,
          content TEXT NOT NULL,
          context TEXT,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
      SQL
      @conn.execute(<<~SQL)
        CREATE VIRTUAL TABLE IF NOT EXISTS riggs_memories_fts USING fts5(
          content,
          content='riggs_memories',
          content_rowid='id'
        )
      SQL
      # Triggers may already exist from init schema
      begin
        @conn.execute(<<~SQL)
          CREATE TRIGGER IF NOT EXISTS riggs_memories_ai AFTER INSERT ON riggs_memories BEGIN
            INSERT INTO riggs_memories_fts(rowid, content) VALUES (new.id, new.content);
          END
        SQL
      rescue SQLite3::SQLException
        # ignore if fts/triggers already wired differently
      end
    end

    def recall_sqlite_memory(query, min_score:, limit:)
      begin
        @conn.execute("SELECT memory_set_option('min_score', ?)", [min_score])
      rescue StandardError
        nil
      end
      begin
        @conn.execute("SELECT memory_set_option('max_results', ?)", [limit])
      rescue StandardError
        nil
      end

      rows = @conn.execute(<<~SQL, [query.to_s])
        SELECT path, snippet, ranking
        FROM memory_search
        WHERE query = ?
      SQL

      # persist() writes scope "#{context}_by_#{namespace}" — match that suffix exactly
      scoped = rows.select { |r| r["path"].to_s.end_with?("_by_#{@namespace}") }
      scoped.first(limit).map { |r| r["snippet"].to_s }
    end

    def recall_fts(query, limit:)
      # Escape FTS special chars lightly
      q = query.to_s.gsub(/["'*:()]/, " ").split.map { |t| "#{t}*" }.join(" ")
      return [] if q.strip.empty?

      rows = @conn.execute(<<~SQL, [@namespace, q, limit])
        SELECT m.content AS content
        FROM riggs_memories_fts f
        JOIN riggs_memories m ON m.id = f.rowid
        WHERE m.namespace = ? AND riggs_memories_fts MATCH ?
        ORDER BY rank
        LIMIT ?
      SQL
      rows.map { |r| r["content"].to_s }
    rescue SQLite3::SQLException
      # Fallback to LIKE if FTS query fails
      rows = @conn.execute(
        "SELECT content FROM riggs_memories WHERE namespace = ? AND content LIKE ? ORDER BY id DESC LIMIT ?",
        [@namespace, "%#{query}%", limit]
      )
      rows.map { |r| r["content"].to_s }
    end

    def warn_once(msg)
      return if @warned

      @warned = true
      warn "⚠️  #{msg}"
    end
  end
end

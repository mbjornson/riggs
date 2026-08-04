-- db/init_riggs_schema.sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;

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

-- Durable conversation turns: lets a gated run be resumed and inspected.
CREATE TABLE IF NOT EXISTS riggs_messages (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT NOT NULL REFERENCES riggs_sessions(id),
  step_key     TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  role         TEXT NOT NULL,
  content      TEXT,
  tool_call_id TEXT,
  tool_name    TEXT,
  tool_calls   TEXT,
  provider     TEXT,
  created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS riggs_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT REFERENCES riggs_sessions(id),
  event_type TEXT,
  payload TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- FTS fallback when sqlite-memory / sqlite-vector extensions are unavailable
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

CREATE TRIGGER IF NOT EXISTS riggs_memories_ai AFTER INSERT ON riggs_memories BEGIN
  INSERT INTO riggs_memories_fts(rowid, content) VALUES (new.id, new.content);
END;

CREATE TRIGGER IF NOT EXISTS riggs_memories_ad AFTER DELETE ON riggs_memories BEGIN
  INSERT INTO riggs_memories_fts(riggs_memories_fts, rowid, content) VALUES('delete', old.id, old.content);
END;

CREATE TRIGGER IF NOT EXISTS riggs_memories_au AFTER UPDATE ON riggs_memories BEGIN
  INSERT INTO riggs_memories_fts(riggs_memories_fts, rowid, content) VALUES('delete', old.id, old.content);
  INSERT INTO riggs_memories_fts(rowid, content) VALUES (new.id, new.content);
END;

CREATE INDEX IF NOT EXISTS idx_riggs_steps_session ON riggs_steps(session_id);
-- UNIQUE so a caller-supplied seq cannot silently collide and reorder a
-- transcript; the auto-allocated path can't collide but has no constraint of
-- its own. Supersedes the earlier non-unique index of the same columns.
DROP INDEX IF EXISTS idx_riggs_messages_session;
CREATE UNIQUE INDEX IF NOT EXISTS idx_riggs_messages_session_seq ON riggs_messages(session_id, seq);
CREATE INDEX IF NOT EXISTS idx_riggs_audit_session ON riggs_audit(session_id);
CREATE INDEX IF NOT EXISTS idx_riggs_memories_namespace ON riggs_memories(namespace);

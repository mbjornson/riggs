# frozen_string_literal: true

require "test_helper"

class TestMemory < Minitest::Test
  def test_fts_fallback_persist_and_recall
    with_tmp_project do
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      memory = Riggs::MemoryService.new(
        namespace: identity[:memory_namespace],
        db_path: "./db/riggs.sqlite3",
        config: {}
      )
      assert_equal :fts, memory.backend
      memory.persist("User login timeout caused by expired OAuth token", context: "test")
      memory.persist("Unrelated gardening tip about tomatoes", context: "test")
      results = memory.recall("OAuth login timeout")
      memory.close
      assert results.any? { |r| r.include?("OAuth") }, results.inspect
    end
  end

  def test_namespace_isolation
    with_tmp_project do
      a = Riggs::MemoryService.new(namespace: "ns_a", db_path: "./db/riggs.sqlite3", config: {})
      b = Riggs::MemoryService.new(namespace: "ns_b", db_path: "./db/riggs.sqlite3", config: {})
      a.persist("secret alpha payload zebra", context: "t")
      results = b.recall("zebra")
      a.close
      b.close
      assert_empty results
    end
  end

  # Simulate the sqlite-memory extension with a plain table so the vector
  # recall path runs without the native extension installed.
  def vector_backed_service(namespace)
    svc = Riggs::MemoryService.new(namespace: namespace, db_path: "./db/riggs.sqlite3", config: {})
    svc.instance_variable_set(:@backend, :sqlite_memory)
    conn = svc.instance_variable_get(:@conn)
    conn.execute("CREATE TABLE IF NOT EXISTS memory_search (path TEXT, snippet TEXT, ranking REAL, query TEXT)")
    [svc, conn]
  end

  def test_vector_recall_does_not_fall_back_to_other_namespaces
    with_tmp_project do
      svc, conn = vector_backed_service("eng_bob_private")
      conn.execute(
        "INSERT INTO memory_search VALUES (?, ?, ?, ?)",
        ["notes_by_team_shared", "alice secret", 1.0, "oauth"]
      )
      results = svc.recall("oauth")
      svc.close
      assert_empty results
    end
  end

  def test_vector_recall_does_not_substring_match_namespaces
    with_tmp_project do
      svc, conn = vector_backed_service("eng")
      conn.execute(
        "INSERT INTO memory_search VALUES (?, ?, ?, ?)",
        ["notes_by_eng_bob_private", "bob secret", 1.0, "oauth"]
      )
      results = svc.recall("oauth")
      svc.close
      assert_empty results
    end
  end

  def test_vector_recall_returns_own_namespace_rows
    with_tmp_project do
      svc, conn = vector_backed_service("eng_bob_private")
      conn.execute(
        "INSERT INTO memory_search VALUES (?, ?, ?, ?)",
        ["notes_by_eng_bob_private", "bob memo", 1.0, "oauth"]
      )
      results = svc.recall("oauth")
      svc.close
      assert_equal ["bob memo"], results
    end
  end
end

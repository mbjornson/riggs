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
end

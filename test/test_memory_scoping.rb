# frozen_string_literal: true

require_relative "test_helper"

# R11.7. Memory never crosses projects: a fact learned building one product does
# not surface while building another.
class TestMemoryScoping < Minitest::Test
  def test_the_resolved_namespace_carries_the_project
    with_tmp_project do |dir|
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")

      assert_equal "eng_bob_private@#{Riggs::Config::Resolver.project_path(dir)}", identity[:memory_namespace]
    end
  end

  # The property itself, asserted through the service rather than through the
  # namespace string: one project writes, another reads, and the read comes back
  # empty.
  def test_a_memory_written_in_one_project_is_not_recalled_in_another
    with_tmp_project do |dir|
      write_memory(scope_for(dir), "the billing rewrite uses Stripe Connect")

      assert_empty recall_in(scope_for("/Products/other"), "billing")
    end
  end

  def test_a_project_still_recalls_what_it_wrote_itself
    with_tmp_project do |dir|
      write_memory(scope_for(dir), "the billing rewrite uses Stripe Connect")

      refute_empty recall_in(scope_for(dir), "billing"), "scoping must not break recall within one project"
    end
  end

  # Composition scopes BOTH backends with one change. A project_path column
  # would scope the SQL backend and silently miss the sqlite-vector one, which
  # independently scopes by paths ending _by_<namespace> -- the failure mode
  # where recall appears to work in tests and leaks in the field.
  def test_the_vector_backend_scope_suffix_carries_the_project_too
    with_tmp_project do |dir|
      service = Riggs::MemoryService.new(namespace: scope_for(dir), db_path: "./db/riggs.sqlite3")

      assert_includes "context_by_#{service.namespace}", Riggs::Config::Resolver.project_path(dir)
      service.close
    end
  end

  # End to end through the CLI, in two directories sharing one global identity
  # and one database -- the arrangement Phase 11a exists to make possible, and
  # the one where a forgotten composition leaks. Asserting on a hand-built scope
  # string would prove the algebra and miss a call site that never asks for it.
  def test_memory_persisted_in_one_project_is_invisible_from_another
    with_tmp_project do
      capture_io { Riggs::CLI.start(["memory:persist", "the billing rewrite uses Stripe Connect"]) }

      assert_match(/No relevant memories found/, recall_from_another_project("billing"))
    end
  end

  # Memories written before this change carry an uncomposed namespace and match
  # no project. They are not migrated, so nothing is stranded only if there is a
  # way to read them.
  def test_recall_legacy_reads_the_uncomposed_namespace
    with_tmp_project do
      write_memory("eng_bob_private", "a fact from before memory was project scoped")

      out, = capture_io { Riggs::CLI.start(["memory:recall", "project", "--legacy"]) }

      assert_match(/before memory was project scoped/, out)
    end
  end

  def test_recall_without_the_flag_does_not_see_legacy_memories
    with_tmp_project do
      write_memory("eng_bob_private", "a fact from before memory was project scoped")

      out, = capture_io { Riggs::CLI.start(["memory:recall", "project"]) }

      refute_match(/before memory was project scoped/, out)
    end
  end

  private

  def scope_for(project_path)
    "eng_bob_private@#{Riggs::Config::Resolver.project_path(project_path)}"
  end

  def recall_from_another_project(query)
    Dir.mktmpdir("riggs-other-project") do |other|
      Riggs::Trust.default.grant!(Riggs::Config::Resolver.project_path(other))
      Dir.chdir(other) { capture_io { Riggs::CLI.start(["memory:recall", query]) }.first }
    end
  end

  def write_memory(namespace, text)
    service = Riggs::MemoryService.new(namespace: namespace, db_path: "./db/riggs.sqlite3")
    service.persist(text, context: "general")
    service.close
  end

  def recall_in(namespace, query)
    service = Riggs::MemoryService.new(namespace: namespace, db_path: "./db/riggs.sqlite3")
    hits = service.recall(query)
    service.close
    hits
  end
end

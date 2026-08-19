# frozen_string_literal: true

require_relative "test_helper"

# R11.6's roll-up. The list comes from the UNION of two sources that disagree:
# trust.yml, and the project paths sessions actually recorded. Either source
# alone omits real projects.
class TestProjects < Minitest::Test
  def test_a_project_that_ran_but_is_not_trusted_still_appears
    with_tmp_project do
      seed_session("/Products/zeroclaw")

      row = row_for("/Products/zeroclaw")

      refute_nil row, "a path with runs must be listed even when trust was withdrawn"
      refute row[:trusted], "and must report that it is not trusted"
    end
  end

  def test_a_trusted_project_that_never_ran_still_appears
    with_tmp_project do |dir|
      newthing = File.join(dir, "newthing")
      FileUtils.mkdir_p(newthing)
      Riggs::Trust.default.grant!(newthing)

      row = row_for(newthing)

      refute_nil row, "a trusted path with no runs must be listed"
      assert_equal 0, row[:runs]
    end
  end

  # A registry that silently accumulates dead paths becomes a graveyard nobody
  # prunes, and the flag is what makes `riggs trust:forget PATH` an obvious next
  # step rather than a command you have to know exists.
  def test_a_trusted_path_that_no_longer_exists_is_flagged
    with_tmp_project do |dir|
      gone = File.join(dir, "deleted-checkout")
      FileUtils.mkdir_p(gone)
      Riggs::Trust.default.grant!(gone)
      FileUtils.remove_entry(gone)

      refute row_for(gone)[:exists], "a trusted path missing from disk must be reported as missing"
    end
  end

  # Rows written before the column existed are NULL. A roll-up that omits
  # history is a wrong total, not a partial one.
  def test_sessions_that_predate_the_column_appear_as_unattributed
    with_tmp_project do
      seed_session(nil)

      row = report.detect { |r| r[:path].nil? }

      refute_nil row, "NULL project_path must get its own bucket"
      assert_equal 1, row[:runs]
    end
  end

  def test_each_project_reports_its_own_spend
    with_tmp_project do
      seed_session("/Products/one", cost: 1.5)
      seed_session("/Products/two", cost: 0.25)

      assert_in_delta 1.5, row_for("/Products/one")[:cost_usd]
      assert_in_delta 0.25, row_for("/Products/two")[:cost_usd]
    end
  end

  # Router::UNMETERED covers every CLI provider: those calls store a NULL
  # cost_usd, so a project running entirely on a subscription SUMs to NULL.
  # Rendering that as $0.00 is a false record -- work really billed to a
  # subscription, reported as billed to nobody.
  def test_unmetered_work_is_counted_and_never_priced_at_zero
    with_tmp_project do
      seed_session("/Products/cli-only", cost: nil)

      row = row_for("/Products/cli-only")

      assert_nil row[:cost_usd], "a project with no priced calls has no dollar figure"
      assert_equal 1, row[:unmetered_calls]
      assert_equal 0, row[:priced_calls]
    end
  end

  def test_the_command_never_renders_unmetered_work_as_a_zero
    with_tmp_project do
      seed_session("/Products/cli-only", cost: nil)

      out, = capture_io { Riggs::CLI.start(["projects"]) }

      assert_match(%r{/Products/cli-only}, out)
      assert_match(/1 unmetered/, out)
      refute_match(/\$0\.00/, out, "unmetered work must never be rendered as a zero dollar amount")
    end
  end

  def test_the_command_lists_two_products_side_by_side
    with_tmp_project do
      seed_session("/Products/one", cost: 1.5)
      seed_session("/Products/two", cost: 0.25)

      out, = capture_io { Riggs::CLI.start(["projects"]) }

      assert_match(%r{/Products/one}, out)
      assert_match(%r{/Products/two}, out)
    end
  end

  private

  def report
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    rows = Riggs::Projects.new(storage: storage, trust: Riggs::Trust.default).rows
    storage.close
    rows
  end

  def row_for(path)
    report.detect { |r| r[:path] == path }
  end

  def seed_session(project_path, cost: :none)
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    id = storage.create_session(
      workflow_name: "example_triage",
      identity: { id: "eng_bob", memory_namespace: "eng", project_path: project_path }
    )
    record_call(storage, id, cost) unless cost == :none
    storage.close
    id
  end

  def record_call(storage, session_id, cost)
    storage.record_provider_call(
      session_id: session_id, step_key: "classify", provider: "mock", model: "m",
      relay_attempt: 1, usage: { measured: !cost.nil? }, cost_usd: cost
    )
  end
end

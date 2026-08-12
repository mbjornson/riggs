# frozen_string_literal: true

require_relative "test_helper"

# R11.6's roll-up command. The grouping IS the command's purpose, not a mode of
# it, so there is no --by-project flag to forget.
class TestCost < Minitest::Test
  def test_with_no_argument_it_reports_every_project_and_a_total
    with_tmp_project do
      seed("/Products/one", cost: 1.5)
      seed("/Products/two", cost: 0.25)

      out = run_cost

      assert_match(%r{/Products/one}, out)
      assert_match(%r{/Products/two}, out)
      assert_match(/TOTAL.*\$1\.7500/, out)
    end
  end

  # A roll-up that omits history is a wrong total, not a partial one.
  def test_the_total_includes_the_unattributed_bucket
    with_tmp_project do
      seed("/Products/one", cost: 1.0)
      seed(nil, cost: 2.0)

      out = run_cost

      assert_match(/\(unattributed\)/, out)
      assert_match(/TOTAL.*\$3\.0000/, out)
    end
  end

  def test_a_dot_means_the_project_the_command_was_run_in
    with_tmp_project do |dir|
      seed(Riggs::Config::Resolver.project_path(dir), cost: 0.5, provider: "anthropic")
      seed("/Products/elsewhere", cost: 9.0)

      out = run_cost(".")

      assert_match(/anthropic/, out)
      assert_match(/\$0\.5000/, out)
      refute_match(/9\.0000/, out, "a scoped report must not include another project's spend")
    end
  end

  def test_an_absolute_path_matches_exactly
    with_tmp_project do
      seed("/Products/one", cost: 1.5, provider: "openai")

      assert_match(/openai/, run_cost("/Products/one"))
    end
  end

  def test_a_basename_matches_the_one_project_that_carries_it
    with_tmp_project do
      seed("/Products/tradeflow", cost: 1.5, provider: "openai")

      assert_match(/openai/, run_cost("tradeflow"))
    end
  end

  # Two products both checked out as `web` is ordinary. Guessing between them
  # misreports spend, and a misreported figure is worse than a refusal because
  # nothing about it looks wrong.
  def test_a_basename_matching_two_projects_is_an_error_listing_both
    with_tmp_project do
      seed("/Products/alpha/web", cost: 1.0)
      seed("/Products/beta/web", cost: 2.0)

      err = failed_cost("web")

      assert_match(%r{/Products/alpha/web}, err)
      assert_match(%r{/Products/beta/web}, err)
      refute_match(/\$/, err, "an ambiguous selector must report no figure at all")
    end
  end

  def test_an_unknown_project_is_an_error_rather_than_an_empty_report
    with_tmp_project do
      seed("/Products/one", cost: 1.0)

      assert_match(/nope/, failed_cost("nope"))
    end
  end

  # abort writes to stderr, which is unbuffered, so a header printed before the
  # selector resolves reaches the terminal AFTER the error: the operator sees a
  # refusal followed by a bare "== COST ==", which reads like a report that came
  # back empty rather than a command that declined to answer. Found by running
  # it, not by reading it.
  def test_a_refused_selector_prints_no_report_header
    with_tmp_project do
      seed("/Products/one", cost: 1.0)

      out, = capture_io { assert_raises(SystemExit) { Riggs::CLI.start(%w[cost nope]) } }

      refute_match(/COST/, out)
    end
  end

  def test_a_scoped_report_breaks_down_by_provider
    with_tmp_project do
      seed("/Products/one", cost: 1.0, provider: "openai")
      seed("/Products/one", cost: 2.0, provider: "anthropic")

      out = run_cost("/Products/one")

      assert_match(/openai.*\$1\.0000/, out)
      assert_match(/anthropic.*\$2\.0000/, out)
    end
  end

  # The total is where a zero would be most convincing and most wrong: an
  # install running entirely on CLI subscriptions would report its whole spend
  # as $0.00. Summing an empty set of NULLs must stay NULL.
  def test_a_total_with_nothing_priced_reports_no_dollar_amount
    with_tmp_project do
      seed("/Products/cli-only", cost: nil, provider: "claude_cli")
      seed("/Products/also-cli", cost: nil, provider: "codex_cli")

      out = run_cost

      assert_match(/TOTAL.*2 unmetered/, out)
      refute_match(/TOTAL.*\$/, out, "a total with no priced call must carry no dollar amount")
    end
  end

  # The same rule the roll-up follows: work billed to a subscription is never
  # reported as billed to nobody.
  def test_unmetered_work_is_never_rendered_as_a_zero
    with_tmp_project do
      seed("/Products/cli-only", cost: nil, provider: "claude_cli")

      out = run_cost("/Products/cli-only")

      assert_match(/1 unmetered/, out)
      refute_match(/\$0\.00/, out)
    end
  end

  # The (unattributed) bucket is a NULL project_path, and `= NULL` is never
  # true, so an equality test would report that bucket as having no provider
  # calls at all. No CLI selector reaches it today -- ".", an absolute path and
  # a basename all name a real path -- so it is asserted directly rather than
  # left as untested defensive SQL.
  def test_the_unattributed_bucket_is_queryable_by_provider
    with_tmp_project do
      seed(nil, cost: 2.0, provider: "openai")

      assert_equal ["openai"], unattributed_providers.map { |row| row["provider"] }
    end
  end

  private

  def unattributed_providers
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    rows = storage.provider_totals(nil)
    storage.close
    rows
  end

  def run_cost(*args)
    out, = capture_io { Riggs::CLI.start(["cost", *args]) }
    out
  end

  def failed_cost(*args)
    _out, err = capture_io do
      assert_raises(SystemExit) { Riggs::CLI.start(["cost", *args]) }
    end
    err
  end

  def seed(project_path, cost:, provider: "mock")
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    id = storage.create_session(
      workflow_name: "example_triage",
      identity: { id: "eng_bob", memory_namespace: "eng", project_path: project_path }
    )
    storage.record_provider_call(
      session_id: id, step_key: "classify", provider: provider, model: "m",
      relay_attempt: 1, usage: { measured: !cost.nil? }, cost_usd: cost
    )
    storage.close
  end
end

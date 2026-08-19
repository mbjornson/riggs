# frozen_string_literal: true

require_relative "test_helper"

# R11.6. A session belongs to exactly one project for its whole life, so the
# path is recorded once at creation rather than derived later from a working
# directory that has since moved on.
class TestProjectAttribution < Minitest::Test
  def test_a_session_records_the_project_it_ran_in
    with_tmp_project do |dir|
      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")

      id = storage.create_session(
        workflow_name: "example_triage",
        identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
        config_snapshot: {}
      )

      assert_equal Riggs::Config::Resolver.project_path(dir), storage.find_session(id)["project_path"]
      storage.close
    end
  end

  # The column has to be filled by the real run, not only by a direct Storage
  # call. Every earlier attribution attempt in this project wired the store and
  # left the engine handing it nothing.
  def test_a_workflow_run_records_the_project_it_ran_in
    with_tmp_project do |dir|
      capture_io do
        Riggs::CLI.start(["workflow:run", "review_prd", "--user", "pm_alice",
                          "--auto-approve", "--input", "prd:one line prd"])
      end

      assert_equal [Riggs::Config::Resolver.project_path(dir)], recorded_project_paths
    end
  end

  # The point of the column: two products on one machine, one database, and
  # spend that does not pool. A single shared value would satisfy "the column is
  # populated" while making the roll-up meaningless.
  def test_two_projects_writing_to_one_database_land_in_separate_buckets
    with_tmp_project do |dir|
      db = File.expand_path("./db/riggs.sqlite3")
      first = session_in(dir, db)
      second = Dir.mktmpdir("riggs-other-project") do |other|
        Riggs::Trust.default.grant!(Riggs::Config::Resolver.project_path(other))
        Dir.chdir(other) { session_in(other, db) }
      end

      refute_equal first, second, "two projects must not share one attribution bucket"
    end
  end

  # One resolution feeds both the column and the memory namespace. Resolving the
  # project twice is how the two come to disagree.
  def test_a_resolved_identity_carries_the_project_it_resolved_in
    with_tmp_project do |dir|
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")

      assert_equal Riggs::Config::Resolver.project_path(dir), identity[:project_path]
    end
  end

  private

  def session_in(dir, db_path)
    storage = Riggs::Storage.new(db_path: db_path)
    id = storage.create_session(
      workflow_name: "example_triage",
      identity: { id: "eng_bob", memory_namespace: "eng", project_path: Riggs::Config::Resolver.project_path(dir) },
      config_snapshot: {}
    )
    path = storage.find_session(id)["project_path"]
    storage.close
    path
  end

  def recorded_project_paths
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    paths = storage.db.execute("SELECT DISTINCT project_path FROM riggs_sessions").map { |r| r["project_path"] }
    storage.close
    paths
  end
end

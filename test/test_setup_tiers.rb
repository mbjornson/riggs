# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestSetupTiers < Minitest::Test
  def setup
    Riggs::Config::Resolver.reset_cache!
  end

  def teardown
    Riggs::Config::Resolver.reset_cache!
  end

  def test_fresh_setup_makes_identity_loadable
    with_setup { |home, repo| assert_identity_loads(home, repo) }
  end

  def test_running_setup_twice_keeps_global_config_and_repairs_skills
    with_setup { |home, repo| assert_second_setup_preserves_global(home, repo) }
  end

  def test_existing_global_config_uses_its_configured_database_path
    with_home_and_repo { |home, repo| assert_configured_database_is_prepared(home, repo) }
  end

  def test_first_global_creation_seeds_legacy_users_and_roles
    with_legacy_config(seed_config) { |home, repo| assert_seeded_people(home, repo) }
  end

  def test_seeding_keeps_operator_owned_provider_fields_and_drops_credentials
    with_legacy_config(provider_config) { |home, repo| assert_safe_provider_seed(home, repo) }
  end

  def test_global_config_is_private_to_its_owner
    with_setup { |home, _repo| assert_equal 0o600, File.stat(global_path(home)).mode & 0o777 }
  end

  def test_project_skeleton_is_commented_and_only_names_permitted_keys
    with_setup { |_home, repo| assert_commented_skeleton(repo) }
  end

  def test_seeding_does_not_run_when_global_config_exists
    with_two_legacy_projects { |home, first, second| assert_first_seed_wins(home, first, second) }
  end

  def test_home_project_does_not_overwrite_global_tier
    with_home_project { |home| assert_home_has_global_users(home) }
  end

  def test_setup_records_trust_for_the_canonical_project_path
    with_setup { |home, repo| assert_trusted(home, repo) }
  end

  def test_project_skeleton_does_not_trip_a_configuration_error
    with_setup { |home, repo| refute_nil resolved_config(home, repo)[:default_user] }
  end

  # Every other test here calls Setup directly with an explicit home, which is
  # what left the CLI's own wiring the one untested part of this task: the
  # `home:` parameter exists FOR testability, so nothing exercised how the Thor
  # command fills it. It filled it from Dir.home while every reader --
  # Trust.home, Resolver.global_config, Trust.default_path -- honours
  # RIGGS_HOME. With RIGGS_HOME set, setup wrote a global tier nothing would
  # ever read, so the fresh-install failure this task exists to fix survived it.
  #
  # The store is deliberately NOT named ".riggs": deriving it as
  # File.dirname(Trust.home) passes only while RIGGS_HOME ends in that literal.
  def test_setup_writes_the_global_tier_where_the_readers_look
    Dir.mktmpdir do |dir|
      elsewhere = File.join(dir, "elsewhere", "riggs-store")
      fake_home = File.join(dir, "home")
      repo = File.join(dir, "repo")
      [fake_home, repo].each { |path| FileUtils.mkdir_p(path) }
      with_env("HOME" => fake_home, "RIGGS_HOME" => elsewhere) do
        Dir.chdir(repo) { capture_io { Riggs::CLI.start(["setup"]) } }
      end

      assert File.exist?(File.join(elsewhere, "config.yml")), "setup must write where every reader looks"
      refute File.exist?(File.join(fake_home, ".riggs", "config.yml")),
             "setup must not write beside HOME when the operator redirected RIGGS_HOME"
    end
  end

  private

  def with_setup
    with_home_and_repo do |home, repo|
      run_setup(home, repo)
      yield home, repo
    end
  end

  def with_legacy_config(config)
    with_home_and_repo do |home, repo|
      write_legacy(repo, config)
      yield home, repo
    end
  end

  def with_home_and_repo
    Dir.mktmpdir { |dir| yield(*home_and_repo(dir)) }
  end

  def home_and_repo(dir)
    paths = [File.join(dir, "home"), File.join(dir, "repo")]
    paths.each { |path| FileUtils.mkdir_p(path) }
  end

  def with_two_legacy_projects
    Dir.mktmpdir { |dir| yield(*two_legacy_projects(dir)) }
  end

  def two_legacy_projects(dir)
    paths = %w[home first second].map { |name| File.join(dir, name) }
    paths.each { |path| FileUtils.mkdir_p(path) }
    write_legacy(paths[1], "users" => { "a" => { "role" => "pm" } })
    write_legacy(paths[2], "users" => { "b" => { "role" => "pm" } })
    paths
  end

  def with_home_project
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      FileUtils.mkdir_p(home)
      run_setup(home, home)
      yield home
    end
  end

  def run_setup(home, cwd)
    Riggs::CLI::Setup.new(riggs_home: File.join(home, ".riggs"), cwd: cwd).call
  end

  def write_legacy(repo, config)
    File.write(File.join(repo, ".agent_hubrc"), Psych.dump(config))
  end

  def global_path(home)
    File.join(home, ".riggs", "config.yml")
  end

  def trust(home)
    Riggs::Trust.new(path: File.join(home, ".riggs", "trust.yml"))
  end

  def resolved_config(home, repo)
    Riggs::Identity.resolved(cwd: repo, trust: trust(home), global_config: global_path(home)).config
  end

  def assert_identity_loads(home, repo)
    config = Riggs::Identity.load_config(nil, cwd: repo, trust: trust(home), global_config: global_path(home))
    assert_equal "pm_alice", Riggs::Identity.resolve(config: config)[:id]
  end

  def assert_second_setup_preserves_global(home, repo)
    before = File.read(global_path(home))
    FileUtils.rm_rf(File.join(home, ".riggs", "skills"))
    run_setup(home, repo)
    assert_equal before, File.read(global_path(home))
    assert File.directory?(File.join(home, ".riggs", "skills"))
  end

  def assert_configured_database_is_prepared(home, repo)
    path = File.join(home, "custom.sqlite3")
    write_global_config(home, path)
    run_setup(home, repo)
    assert File.exist?(path)
  end

  def write_global_config(home, database_path)
    FileUtils.mkdir_p(File.dirname(global_path(home)))
    File.write(global_path(home), Psych.dump("sqlite_path" => database_path))
  end

  def assert_seeded_people(home, repo)
    run_setup(home, repo)
    config = yaml(global_path(home))
    assert_equal({ "role" => "pm" }, config["users"]["matt"])
    assert_equal %w[publish], config["roles"]["pm"]
  end

  def assert_safe_provider_seed(home, repo)
    output = capture_io { run_setup(home, repo) }.first
    raw = File.binread(global_path(home))
    %w[type model base_url pricing relay_chain auth].each { |field| assert_includes raw, field }
    refute_includes raw, "sk-live-SENTINEL-4c1a"
    refute_includes raw, "api_key"
    assert_includes output, "api_key"
  end

  def assert_commented_skeleton(repo)
    raw = File.read(File.join(repo, ".riggs", "config.yml"))
    refute_match(/^\s*(sqlite_path|sqlite_memory)/, raw)
    raw.each_line { |line| assert_comment_or_blank(line) }
  end

  def assert_comment_or_blank(line)
    return if line.strip.empty? || line.strip.start_with?("#")

    flunk "skeleton must be fully commented; found live line: #{line.inspect}"
  end

  def assert_first_seed_wins(home, first, second)
    run_setup(home, first)
    run_setup(home, second)
    users = yaml(global_path(home))["users"]
    assert users.key?("a")
    refute users.key?("b")
  end

  def assert_home_has_global_users(home)
    refute_nil yaml(global_path(home))["users"]
  end

  def assert_trusted(home, repo)
    assert trust(home).trusted?(File.realpath(repo))
  end

  def with_env(values)
    prior = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    Riggs::Config::Resolver.reset_cache!
    yield
  ensure
    prior.each { |key, value| ENV[key] = value }
    Riggs::Config::Resolver.reset_cache!
  end

  def yaml(path)
    Psych.safe_load(File.read(path), aliases: true)
  end

  def seed_config
    { "users" => { "matt" => { "role" => "pm" } }, "roles" => { "pm" => %w[publish] } }
  end

  def provider_config
    { "providers" => { "openai" => provider_fields.merge("api_key" => "sk-live-SENTINEL-4c1a") } }
  end

  def provider_fields
    { "type" => "openai", "model" => "gpt-5", "base_url" => "https://example.test/v1", "pricing" => { "input" => 1 },
      "relay_chain" => ["mock"], "auth" => "env" }
  end
end

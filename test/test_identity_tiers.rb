# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestIdentityTiers < Minitest::Test
  def setup
    Riggs::Config::Resolver.reset_cache!
  end

  def teardown
    Riggs::Config::Resolver.reset_cache!
  end

  def sandbox
    Dir.mktmpdir do |dir|
      root = File.realpath(dir)
      trust = Riggs::Trust.new(path: File.join(root, "trust.yml"))
      global = File.join(root, "global.yml")
      File.write(global, Psych.dump(
                           "default_user" => "matt",
                           "roles" => { "pm" => %w[publish read_workflow] },
                           "users" => { "matt" => { "role" => "pm" } },
                           "providers" => { "mock" => { "type" => "mock" } }
                         ))
      yield(root, trust, global)
    end
  end

  def resolved(root, trust, global)
    Riggs::Identity.resolved(cwd: root, trust: trust, global_config: global)
  end

  def write_project(root, hash)
    FileUtils.mkdir_p(File.join(root, ".riggs"))
    File.write(File.join(root, ".riggs", "config.yml"), Psych.dump(hash))
  end

  def test_the_merged_config_is_the_global_tier_when_no_project_file_exists
    sandbox do |root, trust, global|
      result = resolved(root, trust, global)
      assert_equal "matt", result.config[:default_user]
      assert_equal root, result.project_path
    end
  end

  def test_a_trusted_project_tier_merges_and_carries_provenance
    sandbox do |root, trust, global|
      write_project(root, "default_user" => "sam", "users" => { "sam" => { "role" => "pm" } })
      trust.grant!(root)
      result = resolved(root, trust, global)
      assert_equal "sam", result.config[:default_user]
      assert_equal :project, result.provenance[:default_user]
      assert_equal :global, result.provenance[:users][:matt]
      assert_equal :project, result.provenance[:users][:sam]
    end
  end

  def test_an_untrusted_project_tier_contributes_nothing
    sandbox do |root, trust, global|
      write_project(root, "default_user" => "sam", "users" => { "sam" => { "role" => "pm" } })
      result = resolved(root, trust, global)
      assert_equal "matt", result.config[:default_user]
      refute result.trusted
    end
  end

  def test_identity_resolve_reads_a_project_added_user_after_trust
    sandbox do |root, trust, global|
      write_project(root, "users" => { "sam" => { "role" => "pm", "name" => "Sam" } })
      trust.grant!(root)
      cfg = resolved(root, trust, global).config
      identity = Riggs::Identity.resolve(cli_user: "sam", config: cfg)
      assert_equal "Sam", identity[:name]
      assert_includes identity[:permissions], "publish"
    end
  end

  def test_load_config_still_returns_a_plain_symbolized_hash
    sandbox do |root, trust, global|
      cfg = Riggs::Identity.load_config(nil, cwd: root, trust: trust, global_config: global)
      assert_kind_of Hash, cfg
      assert_equal "matt", cfg[:default_user]
    end
  end

  def test_load_config_with_an_explicit_path_still_reads_only_that_file
    sandbox do |root, _trust, _global|
      with_riggs_home(root) do
        path = Riggs::Config::Resolver.global_config
        File.write(path, Psych.dump("default_user" => "solo", "users" => { "solo" => { "role" => "viewer" } }))
        cfg = Riggs::Identity.load_config(path)
        assert_equal "solo", cfg[:default_user]
      end
    end
  end

  def with_riggs_home(home)
    previous = ENV.fetch("RIGGS_HOME", nil)
    ENV["RIGGS_HOME"] = home
    yield
  ensure
    ENV["RIGGS_HOME"] = previous
  end
end

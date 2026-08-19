# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestTierRoots < Minitest::Test
  def with_riggs_home(path)
    prior = ENV.fetch("RIGGS_HOME", nil)
    ENV["RIGGS_HOME"] = path
    FileUtils.mkdir_p(path)
    Riggs::Config::Resolver.reset_cache!
    yield
  ensure
    ENV["RIGGS_HOME"] = prior
    Riggs::Config::Resolver.reset_cache!
  end

  def workflow_yaml(name)
    Psych.dump(
      "name" => name, "display_name" => name,
      "triggers" => [{ "type" => "keyword", "keywords" => ["shipit"] }],
      "steps" => [{ "id" => "a", "kind" => "prompt", "prompt" => "hi" }]
    )
  end

  def test_a_project_workflow_shadows_a_global_one_of_the_same_name
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      global = File.join(dir, "global")
      [project, global].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(project, "triage.yml"), workflow_yaml("triage"))
      File.write(File.join(global, "triage.yml"), workflow_yaml("triage"))
      File.write(File.join(global, "deploy.yml"), workflow_yaml("deploy"))

      found = Riggs::Triggers.list_declared(roots: [project, global])
      assert_equal %w[deploy triage], found.map { |workflow| workflow[:name] }.sort
      triage = found.detect { |workflow| workflow[:name] == "triage" }
      assert_equal File.join(project, "triage.yml"), triage[:path]
      # Both roots here are explicit temp directories, so neither equals
      # Trust.home/workflows or the bundled path and tier_for reports :project
      # for both. Shadowing is what this test asserts; tier LABELLING is
      # asserted below against real roots, where the comparison is meaningful.
      assert_equal :project, triage[:tier]
    end
  end

  def test_tier_labels_the_real_global_and_bundled_roots
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        global = File.join(home, ".riggs", "workflows")
        FileUtils.mkdir_p(global)
        File.write(File.join(global, "deploy.yml"), workflow_yaml("deploy"))
        Dir.mktmpdir do |repo|
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            declared = Riggs::Triggers.list_declared
            assert_equal :global, declared.detect { |workflow| workflow[:name] == "deploy" }[:tier]
            bundled = declared.detect { |workflow| workflow[:name] == "example_triage" }
            assert_equal :bundled, bundled[:tier], "the third tier must label itself too"
          end
        end
      end
    end
  end

  def test_a_global_workflow_is_matchable_from_a_project_that_does_not_define_it
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      global = File.join(dir, "global")
      [project, global].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(global, "deploy.yml"), workflow_yaml("deploy"))

      matched = Riggs::Triggers.find_workflows(text: "please shipit now", roots: [project, global])
      assert_equal ["deploy"], matched.map { |workflow| workflow[:name] }
    end
  end

  def test_the_dir_keyword_still_works_as_a_single_root
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "solo.yml"), workflow_yaml("solo"))
      assert_equal ["solo"], Riggs::Triggers.list_declared(dir: dir).map { |workflow| workflow[:name] }
    end
  end

  def test_list_declared_stays_sorted_by_name_across_roots
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      global = File.join(dir, "global")
      [project, global].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(project, "zulu.yml"), workflow_yaml("zulu"))
      File.write(File.join(global, "alpha.yml"), workflow_yaml("alpha"))
      names = Riggs::Triggers.list_declared(roots: [project, global]).map { |workflow| workflow[:name] }
      assert_equal %w[alpha zulu], names, "output must not become root-order-dependent"
    end
  end

  def test_skill_roots_place_the_global_tier_between_project_and_bundled
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            Riggs::Trust.default.grant!(Riggs::Config::Resolver.project_path)
            roots = Riggs::SkillRegistry.new.send(:default_roots)
            assert_equal 3, roots.length
            assert_includes roots[0], File.join("config", "riggs", "skills")
            assert_equal File.join(home, ".riggs", "skills"), roots[1]
          end
        end
      end
    end
  end

  def test_the_bundled_skill_root_actually_exists
    root = Riggs::SkillRegistry.new.send(:default_roots).last
    assert File.directory?(root), "bundled skill root #{root} must exist; ../../ resolved to lib/config/"
  end

  # R11.9 #1a: an untrusted repo contributes nothing, and resolution falls
  # through rather than failing.
  def test_an_untrusted_project_contributes_no_skill_or_workflow_root
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          path = File.join(repo, "config", "riggs", "workflows", "sneaky.yml")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, workflow_yaml("sneaky"))
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            assert_equal 2, Riggs::SkillRegistry.new.send(:default_roots).length
            refute_includes Riggs::Triggers.list_declared.map { |workflow| workflow[:name] }, "sneaky"
          end
        end
      end
    end
  end

  def test_an_untrusted_project_workflow_is_not_findable_by_name
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          path = File.join(repo, "config", "riggs", "workflows", "sneaky.yml")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, workflow_yaml("sneaky"))
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            assert_nil Riggs::Triggers.find_path("sneaky"),
                       "loading is a different path from listing; both must be gated"
          end
        end
      end
    end
  end

  def test_a_trusted_project_workflow_is_findable_by_name
    Dir.mktmpdir do |home|
      with_riggs_home(File.join(home, ".riggs")) do
        Dir.mktmpdir do |repo|
          path = File.join(repo, "config", "riggs", "workflows", "mine.yml")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, workflow_yaml("mine"))
          Dir.chdir(repo) do
            Riggs::Config::Resolver.reset_cache!
            Riggs::Trust.default.grant!(Riggs::Config::Resolver.project_path)
            expected = File.join(Riggs::Config::Resolver.project_path, "config", "riggs", "workflows", "mine.yml")
            assert_equal expected, Riggs::Triggers.find_path("mine")
          end
        end
      end
    end
  end
end

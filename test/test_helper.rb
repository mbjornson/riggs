# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "riggs"
require "fileutils"
require "tmpdir"
require "yaml"

require "minitest/autorun"

module RiggsTestHelpers
  def with_tmp_project
    Dir.mktmpdir("riggs-test") do |dir|
      Dir.mktmpdir("riggs-home") do |home|
        prior = ENV.fetch("RIGGS_HOME", nil)
        ENV["RIGGS_HOME"] = File.join(home, ".riggs")
        Riggs::Config::Resolver.reset_cache!
        Dir.chdir(dir) do
          FileUtils.mkdir_p("config/riggs/workflows")
          FileUtils.mkdir_p("config/riggs/skills/triage_v1")
          FileUtils.mkdir_p("db")
          write_global_config(dir)
          copy_example_workflow
          copy_skill
          Riggs::Storage.new(db_path: "./db/riggs.sqlite3").close
          Riggs::Trust.default.grant!(Riggs::Config::Resolver.project_path(dir))
          yield dir
        end
      ensure
        ENV["RIGGS_HOME"] = prior
        Riggs::Config::Resolver.reset_cache!
      end
    end
  end

  # The former write_hubrc content, moved to the tier that is allowed to hold
  # it. sqlite_path stays absolute-to-the-temp-project so each test keeps its
  # own database.
  def write_global_config(dir)
    FileUtils.mkdir_p(ENV.fetch("RIGGS_HOME"))
    File.write(File.join(ENV.fetch("RIGGS_HOME"), "config.yml"), <<~YAML)
      default_user: eng_bob
      users:
        pm_alice:
          id: pm_alice
          name: Alice PM
          role: pm
          memory_namespace: team_shared
        eng_bob:
          id: eng_bob
          name: Bob Eng
          role: engineer
          memory_namespace: eng_bob_private
        view_cara:
          id: view_cara
          name: Cara
          role: viewer
          memory_namespace: readonly
      roles:
        pm: [edit_workflow, manage_skills, configure_memory, publish, read_workflow, inspect_run]
        engineer: [run_workflow, approve_gates, read_workflow, inspect_run, manage_mcp]
        viewer: [read_workflow, inspect_run]
      sqlite_path: "#{File.join(dir, 'db', 'riggs.sqlite3')}"
      providers:
        mock:
          type: mock
    YAML
  end

  def write_hubrc
    File.write(".agent_hubrc", <<~YAML)
      default_user: eng_bob
      users:
        pm_alice:
          id: pm_alice
          name: Alice PM
          role: pm
          memory_namespace: team_shared
        eng_bob:
          id: eng_bob
          name: Bob Eng
          role: engineer
          memory_namespace: eng_bob_private
        view_cara:
          id: view_cara
          name: Cara
          role: viewer
          memory_namespace: readonly
      roles:
        pm: [edit_workflow, manage_skills, configure_memory, publish, read_workflow, inspect_run]
        engineer: [run_workflow, approve_gates, read_workflow, inspect_run, manage_mcp]
        viewer: [read_workflow, inspect_run]
      sqlite_path: "./db/riggs.sqlite3"
      providers:
        mock:
          type: mock
    YAML
  end

  def copy_example_workflow
    src = File.expand_path("../config/riggs/workflows/example_triage.yml", __dir__)
    FileUtils.cp(src, "config/riggs/workflows/example_triage.yml")
  end

  def copy_skill
    src = File.expand_path("../config/riggs/skills/triage_v1/SKILL.yml", __dir__)
    FileUtils.cp(src, "config/riggs/skills/triage_v1/SKILL.yml")
  end
end

class Minitest::Test
  include RiggsTestHelpers
end

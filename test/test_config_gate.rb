# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

class TestConfigGate < Minitest::Test
  def test_untrusted_load_fails_closed
    with_untrusted_project do
      error = assert_raises(Riggs::Error) { Riggs::Identity.load_file!(".agent_hubrc") }
      assert_match(/not trusted/i, error.message)
      assert_match(/riggs trust/i, error.message)
    end
  end

  def test_untrusted_config_cannot_resolve_an_attacker_role
    with_untrusted_project do
      assert_raises(Riggs::Error) { Riggs::Identity.resolve(cli_user: "attacker") }
    end
  end

  def test_trust_then_load_succeeds
    with_untrusted_project do
      trust_config
      config = Riggs::Identity.load_file!(".agent_hubrc")
      assert_equal "attacker", config[:default_user].to_s
    end
  end

  def test_a_fingerprint_change_invalidates_trust
    with_untrusted_project do
      trust_config
      File.write(".agent_hubrc", "#{File.read('.agent_hubrc')}\n# touched\n")
      error = assert_raises(Riggs::Error) { Riggs::Identity.load_file!(".agent_hubrc") }
      assert_match(/not trusted/i, error.message)
    end
  end

  def test_the_tty_prompt_grants_trust
    with_untrusted_project do
      stdin = StringIO.new("y\n")
      def stdin.tty? = true

      output = StringIO.new
      gate = Riggs::Trust::ConfigGate.new(trust: Riggs::Trust.default, io: output, stdin: stdin)
      gate.ensure!(Dir.pwd, ".agent_hubrc")
      assert Riggs::Trust.default.config_current?(Dir.pwd, ".agent_hubrc")
      assert_match(/Trust this project's/i, output.string)
    end
  end

  def test_load_config_untrusted_bypasses_the_gate
    with_untrusted_project do
      config = Riggs::Identity.load_config_untrusted(".agent_hubrc")
      assert_equal "attacker", config[:default_user].to_s
    end
  end

  # The global tier is operator-owned: it is the file the operator writes, not
  # one a repository ships. Gating it behind project trust would make every
  # command in an untrusted directory fail on the operator's own config -- and
  # the whole suite reads it, so this would surface as total breakage rather
  # than as one wrong refusal.
  def test_the_global_tier_is_never_gated_by_project_trust
    with_tmp_project do |dir|
      Riggs::Trust.default.forget!(Riggs::Config::Resolver.project_path(dir))

      config = Riggs::Identity.load_file!(Riggs::Config::Resolver.global_config)

      assert config.key?(:users), "the global tier must load without a project grant"
    end
  end

  # `of` answers nil for a file that is not there. A record written while the
  # config was missing therefore compared nil == nil and reported the file as
  # the trusted one -- fail-open in the direction the gate exists to close.
  def test_a_missing_config_is_never_reported_as_current
    with_tmp_project do |dir|
      project = Riggs::Config::Resolver.project_path(dir)
      absent = File.join(dir, "gone", "config.yml")
      trust = Riggs::Trust.default
      trust.grant!(project)
      trust.record_config!(project, absent)

      refute trust.config_current?(project, absent), "a config that is not on disk cannot be the trusted one"
    end
  end

  def test_default_imports_a_legacy_trust_record_once
    with_untrusted_project do
      write_legacy_record
      trust = Riggs::Trust.default

      assert trust.config_current?(Dir.pwd, ".agent_hubrc")
      first = File.read(trust.path)
      Riggs::Trust.default
      assert_equal first, File.read(trust.path)
      assert_includes first, "legacy_project_trust_imported: true"
    end
  end

  private

  def with_untrusted_project
    Dir.mktmpdir("riggs-untrusted") do |dir|
      with_riggs_home(dir) do
        Dir.chdir(dir) do
          write_hostile_config
          yield
        end
      end
    end
  end

  def with_riggs_home(dir)
    previous = ENV.fetch("RIGGS_HOME", nil)
    ENV["RIGGS_HOME"] = File.join(dir, ".riggs")
    yield
  ensure
    ENV["RIGGS_HOME"] = previous
  end

  def write_hostile_config
    File.write(".agent_hubrc", <<~YAML)
      default_user: attacker
      users:
        attacker:
          id: attacker
          role: pm
      roles:
        pm: [run_workflow]
      providers:
        mock:
          type: mock
    YAML
  end

  def trust_config
    trust = Riggs::Trust.default
    trust.grant!(Dir.pwd)
    trust.record_config!(Dir.pwd, ".agent_hubrc")
  end

  def write_legacy_record
    FileUtils.mkdir_p(ENV.fetch("RIGGS_HOME"))
    record = { "config_path" => File.expand_path(".agent_hubrc"), "fingerprint" => "old" }
    File.write(File.join(ENV.fetch("RIGGS_HOME"), "trusted_projects.json"), JSON.generate(Dir.pwd => record))
  end
end

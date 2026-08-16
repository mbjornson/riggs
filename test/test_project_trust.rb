# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestProjectTrust < Minitest::Test
  def with_untrusted_project
    Dir.mktmpdir("riggs-untrusted") do |dir|
      Dir.chdir(dir) do
        ENV["RIGGS_TRUST_HOME"] = File.join(dir, ".trust-home")
        FileUtils.mkdir_p(ENV.fetch("RIGGS_TRUST_HOME"))
        File.write(".agent_hubrc", <<~YAML)
          default_user: attacker
          users:
            attacker:
              id: attacker
              name: Attacker
              role: pm
              memory_namespace: pwned
          roles:
            pm: [edit_workflow, manage_skills, configure_memory, publish, read_workflow, inspect_run, run_workflow, manage_mcp]
          mcp_servers:
            evil:
              command: /bin/echo
              args: ["pwned"]
          providers:
            mock:
              type: mock
          sqlite_path: "./db/riggs.sqlite3"
        YAML
        yield dir
      end
    end
  ensure
    ENV.delete("RIGGS_TRUST_HOME")
  end

  def test_untrusted_load_config_fails_closed
    with_untrusted_project do
      err = assert_raises(Riggs::Error) { Riggs::Identity.load_config }
      assert_match(/not trusted/i, err.message)
      assert_match(/riggs trust/i, err.message)
    end
  end

  def test_untrusted_cannot_resolve_attacker_role
    with_untrusted_project do
      assert_raises(Riggs::Error) { Riggs::Identity.resolve(cli_user: "attacker") }
    end
  end

  def test_trust_then_load_succeeds
    with_untrusted_project do
      Riggs::ProjectTrust.trust!(Dir.pwd, config_path: ".agent_hubrc")
      cfg = Riggs::Identity.load_config
      assert_equal "attacker", cfg[:default_user].to_s
    end
  end

  def test_fingerprint_change_invalidates_trust
    with_untrusted_project do
      Riggs::ProjectTrust.trust!(Dir.pwd, config_path: ".agent_hubrc")
      File.write(".agent_hubrc", "#{File.read('.agent_hubrc')}\n# touched\n")
      err = assert_raises(Riggs::Error) { Riggs::Identity.load_config }
      assert_match(/not trusted/i, err.message)
    end
  end

  def test_tty_prompt_yes_trusts
    with_untrusted_project do
      stdin = StringIO.new("y\n")
      def stdin.tty? = true
      stderr = StringIO.new
      Riggs::ProjectTrust.ensure!(Dir.pwd, config_path: ".agent_hubrc", io: stderr, stdin: stdin)
      assert Riggs::ProjectTrust.trusted?(Dir.pwd, config_path: ".agent_hubrc")
      assert_match(/Trust this project's/i, stderr.string)
    end
  end

  def test_load_config_untrusted_does_not_require_trust
    with_untrusted_project do
      cfg = Riggs::Identity.load_config_untrusted
      assert_equal "attacker", cfg[:default_user].to_s
    end
  end
end

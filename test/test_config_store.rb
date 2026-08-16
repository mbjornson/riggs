# frozen_string_literal: true

require "test_helper"
require "json"

class TestConfigStore < Minitest::Test
  def test_public_view_masks_secrets
    with_tmp_project do
      File.write(".agent_hubrc", <<~YAML)
        default_user: eng_bob
        users:
          eng_bob:
            id: eng_bob
            name: Bob
            role: engineer
            memory_namespace: eng
        roles:
          engineer: [run_workflow, read_workflow, inspect_run, approve_gates, manage_mcp]
        sqlite_path: "./db/riggs.sqlite3"
        providers:
          claude:
            type: anthropic
            api_key: "sk-secret-value"
      YAML
      trust_hubrc!

      view = Riggs::ConfigStore.new.public_view
      assert_equal "••••••••", view.dig("providers", "claude", "api_key")
      assert_equal "anthropic", view.dig("providers", "claude", "type")
    end
  end

  def test_merge_writes_backup_and_preserves_unrelated_keys
    with_tmp_project do
      store = Riggs::ConfigStore.new
      before = store.read
      store.merge!("providers" => { "mock" => { "type" => "mock" }, "extra" => { "type" => "ollama" } })

      after = Riggs::Identity.load_config_untrusted(store.path)
      assert_equal "ollama", after.dig(:providers, :extra, :type) || after.dig("providers", "extra", "type")
      assert before[:users] || before["users"]
      backups = Dir.glob(".agent_hubrc.bak.*")
      assert backups.any?, "expected backup file"
    end
  end

  def test_write_and_merge_invalidate_project_trust
    with_tmp_project do
      store = Riggs::ConfigStore.new
      assert Riggs::ProjectTrust.trusted?(Dir.pwd, config_path: store.path)

      store.merge!("providers" => { "mock" => { "type" => "mock" } })
      refute Riggs::ProjectTrust.trusted?(Dir.pwd, config_path: store.path),
             "merge! must not re-trust after changing .agent_hubrc bytes"

      trust_hubrc!(store.path)
      assert Riggs::ProjectTrust.trusted?(Dir.pwd, config_path: store.path)

      store.write!("default_user" => "eng_bob", "users" => {})
      refute Riggs::ProjectTrust.trusted?(Dir.pwd, config_path: store.path),
             "write! must not re-trust after changing .agent_hubrc bytes"
    end
  end

  def test_write_rejects_non_hash_and_leaves_file_intact
    with_tmp_project do
      store = Riggs::ConfigStore.new
      original = File.read(store.path)

      error = assert_raises(Riggs::Error) { store.write!([{ "users" => {} }]) }
      assert_match(/hash/i, error.message)
      assert_equal original, File.read(store.path)

      error = assert_raises(Riggs::Error) { store.write!("not-a-document") }
      assert_match(/hash/i, error.message)
      assert_equal original, File.read(store.path)
    end
  end
end

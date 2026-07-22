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

      after = store.read
      assert_equal "ollama", after.dig(:providers, :extra, :type) || after.dig("providers", "extra", "type")
      assert before[:users] || before["users"]
      backups = Dir.glob(".agent_hubrc.bak.*")
      assert backups.any?, "expected backup file"
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "json"

class TestConfigStore < Minitest::Test
  def test_public_view_masks_secrets
    with_tmp_project do
      File.write(Riggs::Config::Resolver.global_config, <<~YAML)
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
      view = default_store.public_view
      assert_equal "••••••••", view.dig("providers", "claude", "api_key")
      assert_equal "anthropic", view.dig("providers", "claude", "type")
    end
  end

  def test_merge_writes_backup_and_preserves_unrelated_keys
    with_tmp_project do
      store = default_store
      before = store.read
      store.merge!("providers" => { "mock" => { "type" => "mock" }, "extra" => { "type" => "ollama" } })

      after = Riggs::Identity.load_config_untrusted(store.path)
      assert_equal "ollama", after.dig(:providers, :extra, :type) || after.dig("providers", "extra", "type")
      assert before[:users] || before["users"]
      backups = Dir.glob("#{store.path}.bak.*")
      assert backups.any?, "expected backup file"
    end
  end

  def test_default_reads_the_global_tier_when_the_project_declares_no_config
    with_tmp_project do
      store = default_store

      assert_equal :global, store.tier
      assert_equal Riggs::Config::Resolver.global_config, store.path
    end
  end

  def test_default_reads_the_trusted_project_tier_when_one_exists
    with_tmp_project do |dir|
      write_project_config("users" => { "eng_bob" => { "role" => "engineer" } })

      store = default_store

      assert_equal :project, store.tier
      assert_equal File.join(Riggs::Config::Resolver.project_path(dir), ".riggs", "config.yml"), store.path
    end
  end

  # Identity.config_path returns nil for an untrusted project, but a caller can
  # still name the file explicitly -- web/app.rb hands ConfigStore a path, and
  # ConfigStore#read reaches Identity.load_file!, which never consults trust.
  # The refusal has to live here too or the gate has a second door.
  def test_a_store_pointed_at_an_untrusted_project_config_refuses_to_read_it
    with_tmp_project do |dir|
      path = untrusted_project_config(dir, "users" => { "mallory" => { "role" => "engineer" } })

      error = assert_raises(Riggs::Error) do
        Riggs::ConfigStore.new(path: path, tier: :project, trust: Riggs::Trust.default).read
      end

      assert_match(/not trusted/i, error.message)
      assert_match(/riggs trust/i, error.message)
    end
  end

  # A stated tier is checked, not believed. Labelling a project path :global is
  # how a caller would otherwise route untrusted content around every
  # project-tier guard below.
  def test_a_project_path_cannot_be_written_under_the_global_label
    with_tmp_project do |dir|
      path = untrusted_project_config(dir, "users" => {})

      assert_raises(Riggs::Error) do
        Riggs::ConfigStore.new(path: path, tier: :global, trust: Riggs::Trust.default)
      end
    end
  end

  # TierGuard compared raw strings, so `.`, `..` and symlink spellings of the
  # global config were labelled :project -- and write! then truncated the
  # operator's own file, api_key and all, to the project candidate. Trust is
  # granted for each derived path first, so the refusal has to come from the
  # tier check and cannot pass for the untrusted-path reason instead.
  def test_a_respelled_global_config_cannot_be_written_as_the_project_tier
    with_tmp_project do |dir|
      global = Riggs::Config::Resolver.global_config
      link = File.join(dir, "linked-home")
      File.symlink(File.dirname(global), link)

      { "dot-dot" => File.join(File.dirname(global), "..", ".riggs", "config.yml"),
        "dot" => File.join(File.dirname(global), ".", "config.yml"),
        "symlink" => File.join(link, "config.yml") }.each do |label, spelling|
        before = File.binread(global)
        Riggs::Trust.default.grant!(Riggs::Config::Resolver.project_path(File.dirname(spelling)))

        error = assert_raises(Riggs::Error, "#{label} must be refused") do
          Riggs::ConfigStore.new(path: spelling, tier: :project, trust: Riggs::Trust.default).write!({})
        end

        assert_match(/global tier, not the project tier/, error.message, label)
        assert_equal before, File.binread(global), "#{label} must leave the global config untouched"
      end
    end
  end

  def test_the_global_tier_is_still_writable_under_a_respelled_path
    with_tmp_project do
      global = Riggs::Config::Resolver.global_config
      spelling = File.join(File.dirname(global), ".", "config.yml")

      store = Riggs::ConfigStore.new(path: spelling, tier: :global, trust: Riggs::Trust.default)

      assert_equal :global, store.tier
      assert store.read.key?(:users), "a respelled global path must still read the global tier"
    end
  end

  def test_public_view_reports_the_tier_and_path_it_read
    with_tmp_project do
      view = default_store.public_view

      assert_equal "global", view["_tier"]
      assert_equal Riggs::Config::Resolver.global_config, view["_path"]
    end
  end

  # The write path is reachable over HTTP from POST /config, so a rejected key
  # must be rejected BEFORE backup! and File.write. Asserting the raise alone
  # would pass against an implementation that writes first and raises after.
  def test_a_forbidden_project_key_is_rejected_before_the_file_is_touched
    with_tmp_project do
      path = write_project_config("users" => { "eng_bob" => { "role" => "engineer" } })
      before = File.binread(path)

      assert_raises(Riggs::Error) { default_store.merge!("sqlite_path" => "/tmp/evil.db") }

      assert_equal before, File.binread(path), "the project config must be byte-identical after a refusal"
      assert_empty Dir.glob("#{path}.bak.*"), "a refused write must not leave a backup behind"
    end
  end

  def test_a_provider_credential_is_rejected_before_the_file_is_touched
    with_tmp_project do
      path = write_project_config("providers" => { "mock" => { "model" => "m" } })
      before = File.binread(path)

      assert_raises(Riggs::Error) do
        default_store.merge!("providers" => { "mock" => { "api_key" => "sk-leak" } })
      end

      assert_equal before, File.binread(path)
      assert_empty Dir.glob("#{path}.bak.*")
    end
  end

  # The guarantee, not the mechanism: before this validation the write
  # succeeded and every later command in the repository raised on the file the
  # web UI had just written -- a self-inflicted outage reachable from a form.
  def test_a_refused_write_leaves_the_repository_usable
    with_tmp_project do |dir|
      write_project_config("users" => { "eng_bob" => { "role" => "engineer" } })

      assert_raises(Riggs::Error) { default_store.merge!("sqlite_memory" => { "vector_path" => "/tmp/x.so" }) }

      resolved = Riggs::Identity.resolved(cwd: dir, trust: Riggs::Trust.default)
      assert_equal "eng_bob", resolved.config[:default_user].to_s
    end
  end

  # public_view is what GET /api/config returns and what the raw-YAML textarea
  # renders, so its metadata travels back in on the next write. Persisting it
  # would put an unmergeable key in the project tier -- the very failure the
  # validation above exists to prevent, introduced by the label.
  def test_view_metadata_is_never_written_back_to_disk
    with_tmp_project do
      store = default_store
      store.write!(store.public_view)

      written = Psych.safe_load(File.read(store.path), aliases: true)
      refute written.key?("_tier"), "_tier is a view label, not configuration"
      refute written.key?("_path"), "_path is a view label, not configuration"
    end
  end

  def test_write_and_merge_invalidate_project_trust
    with_tmp_project do |dir|
      path = write_project_config("users" => { "eng_bob" => { "role" => "engineer" } })
      trust = Riggs::Trust.default
      project_path = Riggs::Config::Resolver.project_path(dir)
      store = default_store

      assert trust.config_current?(project_path, path)
      store.merge!("providers" => { "mock" => { "model" => "updated" } })
      refute trust.config_current?(project_path, path), "merge! must not re-trust changed config bytes"

      trust.record_config!(project_path, path)
      store.write!("users" => { "eng_bob" => { "role" => "engineer" } })
      refute trust.config_current?(project_path, path), "write! must not re-trust changed config bytes"
    end
  end

  def test_write_rejects_non_hash_and_leaves_file_intact
    with_tmp_project do
      store = default_store
      original = File.read(store.path)

      error = assert_raises(Riggs::Error) { store.write!([{ "users" => {} }]) }
      assert_match(/hash/i, error.message)
      assert_equal original, File.read(store.path)

      error = assert_raises(Riggs::Error) { store.write!("not-a-document") }
      assert_match(/hash/i, error.message)
      assert_equal original, File.read(store.path)
    end
  end

  private

  def default_store
    Riggs::ConfigStore.default(cwd: Dir.pwd, trust: Riggs::Trust.default)
  end

  def write_project_config(values)
    FileUtils.mkdir_p(".riggs")
    path = File.expand_path(File.join(".riggs", "config.yml"))
    File.write(path, Psych.dump(values))
    Riggs::Trust.default.record_config!(Riggs::Config::Resolver.project_path, path)
    path
  end

  # A nested directory carrying its own .riggs/config.yml resolves to itself as
  # a project (ProjectPaths#marked_ancestor), and with_tmp_project granted
  # trust only to the outer directory -- so this path is a real untrusted
  # project rather than a directory that merely lacks a grant.
  def untrusted_project_config(dir, values)
    nested = File.join(dir, "vendor", "cloned")
    FileUtils.mkdir_p(File.join(nested, ".riggs"))
    path = File.join(nested, ".riggs", "config.yml")
    File.write(path, Psych.dump(values))
    Riggs::Config::Resolver.reset_cache!
    path
  end
end

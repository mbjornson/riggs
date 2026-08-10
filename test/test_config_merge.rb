# frozen_string_literal: true

require_relative "test_helper"

class TestConfigMerge < Minitest::Test
  G = "/home/me/.riggs/config.yml"
  P = "/repo/.riggs/config.yml"

  def merge(global, project)
    Riggs::Config::Merge.call(global: global, project: project, global_path: G, project_path: P)
  end

  def test_an_empty_project_tier_returns_the_global_tier
    result = merge({ users: { matt: { role: "pm" } } }, {})
    assert_equal({ matt: { role: "pm" } }, result.config[:users])
  end

  # --- the allowlist ---

  def test_sqlite_path_in_the_project_tier_is_a_hard_error_naming_both_files
    err = assert_raises(Riggs::Error) { merge({}, { sqlite_path: "/tmp/x.sqlite3" }) }
    assert_includes err.message, "sqlite_path"
    assert_includes err.message, G
    assert_includes err.message, P
  end

  # The key a denylist missed. vector_path and memory_path reach
  # enable_load_extension/load_extension, so this is arbitrary native code.
  def test_sqlite_memory_in_the_project_tier_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({}, { sqlite_memory: { vector_path: "/tmp/evil.dylib" } })
    end
    assert_includes err.message, "sqlite_memory"
  end

  def test_an_unrecognized_top_level_key_is_a_hard_error_listing_the_permitted_ones
    err = assert_raises(Riggs::Error) { merge({}, { something_new: true }) }
    assert_includes err.message, "something_new"
    %w[default_user mcp_servers providers roles users].each { |k| assert_includes err.message, k }
  end

  # --- roles: add yes, redefine no ---

  def test_a_project_may_define_a_role_the_global_tier_does_not
    result = merge({ roles: { pm: %w[publish] } }, { roles: { client_reviewer: %w[inspect_run] } })
    assert_equal %w[publish], result.config[:roles][:pm]
    assert_equal %w[inspect_run], result.config[:roles][:client_reviewer]
    assert_equal :project, result.provenance[:roles][:client_reviewer]
    assert_equal :global, result.provenance[:roles][:pm]
  end

  def test_a_project_redefining_a_global_role_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({ roles: { engineer: %w[run_workflow] } }, { roles: { engineer: %w[manage_mcp] } })
    end
    assert_includes err.message, "engineer"
    assert_includes err.message, G
    assert_includes err.message, P
  end

  # --- users: merge by key, override allowed ---

  def test_a_project_may_add_users_and_override_an_existing_role
    result = merge(
      { roles: { pm: [], engineer: [] }, users: { matt: { role: "pm" } } },
      { users: { matt: { role: "engineer" }, sam: { role: "pm" } } }
    )
    assert_equal "engineer", result.config[:users][:matt][:role]
    assert_equal "pm", result.config[:users][:sam][:role]
    assert_equal :project, result.provenance[:users][:matt]
    assert_equal :project, result.provenance[:users][:sam]
  end

  def test_a_project_may_not_rewrite_any_other_field_on_a_globally_defined_user
    err = assert_raises(Riggs::Error) do
      merge({ roles: { pm: [] }, users: { matt: { role: "pm", memory_namespace: "team" } } },
            { users: { matt: { memory_namespace: "hijacked" } } })
    end
    assert_includes err.message, "matt"
    assert_includes err.message, "memory_namespace"
  end

  def test_a_new_project_user_may_set_every_field
    result = merge({ roles: { pm: [] } },
                   { users: { sam: { id: "sam", name: "Sam", role: "pm", memory_namespace: "sam_priv" } } })
    assert_equal "sam_priv", result.config[:users][:sam][:memory_namespace]
  end

  def test_provenance_marks_only_the_users_the_project_touched
    result = merge({ roles: { pm: [], engineer: [] },
                     users: { matt: { role: "pm" }, kim: { role: "engineer" } } },
                   { users: { matt: { role: "engineer" } } })
    assert_equal :project, result.provenance[:users][:matt]
    assert_equal :global, result.provenance[:users][:kim]
  end

  # The distinguishing case: mentioned but unchanged. Without this, the
  # "unless merged[name] == g[name]" guard could be deleted and the test above
  # would still pass.
  def test_restating_a_users_existing_role_does_not_claim_project_provenance
    result = merge({ roles: { pm: [] }, users: { matt: { role: "pm" } } },
                   { users: { matt: { role: "pm" } } })
    assert_equal :global, result.provenance[:users][:matt]
  end

  def test_a_user_naming_an_undefined_role_is_a_hard_error_listing_the_defined_ones
    err = assert_raises(Riggs::Error) do
      merge({ roles: { pm: [] } }, { users: { kim: { role: "client_reviewer" } } })
    end
    assert_includes err.message, "kim"
    assert_includes err.message, "client_reviewer"
    assert_includes err.message, "pm"
  end

  def test_a_user_may_name_a_built_in_role_that_no_config_defines
    result = merge({}, { users: { sam: { role: "viewer" } } })
    assert_equal "viewer", result.config[:users][:sam][:role]
  end

  def test_default_user_from_the_project_must_resolve_in_the_merged_user_set
    ok = merge({ users: { matt: { role: "pm" } } }, { default_user: "matt" })
    assert_equal "matt", ok.config[:default_user]
    assert_equal :project, ok.provenance[:default_user]

    err = assert_raises(Riggs::Error) { merge({ users: { matt: { role: "pm" } } }, { default_user: "ghost" }) }
    assert_includes err.message, "ghost"
  end

  # --- providers: override only, no credentials ---

  def test_a_project_may_override_fields_on_a_globally_defined_provider
    result = merge(
      { providers: { ollama: { type: "ollama", base_url: "http://a" } } },
      { providers: { ollama: { model: "llama3.2" } } }
    )
    assert_equal "ollama", result.config[:providers][:ollama][:type]
    assert_equal "http://a", result.config[:providers][:ollama][:base_url]
    assert_equal "llama3.2", result.config[:providers][:ollama][:model]
  end

  def test_a_project_naming_an_undefined_provider_is_a_hard_error_listing_the_defined_ones
    err = assert_raises(Riggs::Error) do
      merge({ providers: { mock: { type: "mock" } } }, { providers: { sneaky: { type: "anthropic" } } })
    end
    assert_includes err.message, "sneaky"
    assert_includes err.message, "mock"
  end

  def test_api_key_in_the_project_tier_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({ providers: { claude: { type: "anthropic" } } },
            { providers: { claude: { api_key: "sk-live-abc" } } })
    end
    assert_includes err.message, "api_key"
    assert_includes err.message, "claude"
    refute_includes err.message, "sk-live-abc"
  end

  # Banning api_key alone left four other doors open.
  def test_every_provider_field_outside_the_allowlist_is_a_hard_error
    [{ token: "t" }, { secret: "s" }, { password: "p" },
     { auth: { api_key: "sk-nested" } }, { type: "anthropic" }].each do |bad|
      err = assert_raises(Riggs::Error, "#{bad.keys.first} must be rejected") do
        merge({ providers: { claude: { type: "anthropic" } } }, { providers: { claude: bad } })
      end
      assert_includes err.message, bad.keys.first.to_s
    end
  end

  def test_a_plain_auth_string_is_still_permitted
    result = merge({ providers: { claude_cli: { type: "claude_cli" } } },
                   { providers: { claude_cli: { auth: "subscription" } } })
    assert_equal "subscription", result.config[:providers][:claude_cli][:auth]
  end

  # --- mcp_servers: merge, with provenance ---

  def test_a_project_may_add_mcp_servers_without_removing_global_ones
    result = merge(
      { mcp_servers: { context7: { command: "npx" }, honeybadger: { command: "npx" } } },
      { mcp_servers: { projectonly: { command: "./bin/mcp" } } }
    )
    assert_equal %i[context7 honeybadger projectonly].sort, result.config[:mcp_servers].keys.sort
    assert_equal :project, result.provenance[:mcp_servers][:projectonly]
    assert_equal :global, result.provenance[:mcp_servers][:context7]
  end

  def test_a_project_overriding_a_global_mcp_server_is_marked_project_provenance
    result = merge({ mcp_servers: { hb: { command: "npx" } } },
                   { mcp_servers: { hb: { command: "./evil" } } })
    assert_equal "./evil", result.config[:mcp_servers][:hb][:command]
    assert_equal :project, result.provenance[:mcp_servers][:hb]
  end
end

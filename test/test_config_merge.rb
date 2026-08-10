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

  # --- value SHAPE, not just key names ---
  #
  # PROJECT_KEYS and PROVIDER_FIELDS compare NAMES. A value with no keys has
  # no names to compare, so `providers: {openai: "x"}` walked past
  # PROVIDER_FIELDS untouched and replaced the whole global provider entry --
  # model, base_url, pricing, relay_chain and auth all gone. Reproduced before
  # this guard existed: the merge returned {openai: "pwned"} and raised
  # nothing. Checking shape before any algebra runs is what makes the name
  # allowlists mean anything.

  def test_a_provider_declared_as_a_string_is_rejected_not_silently_substituted
    err = assert_raises(Riggs::Error) do
      merge({ providers: { openai: { model: "gpt-5", base_url: "https://internal" } } },
            { providers: { openai: "pwned" } })
    end
    assert_includes err.message, "providers.openai"
    assert_includes err.message, "mapping"
    assert_includes err.message, P
  end

  def test_a_provider_declared_as_a_list_is_rejected
    err = assert_raises(Riggs::Error) do
      merge({ providers: { openai: {} } }, { providers: { openai: [{ api_key: "sk-EVIL" }] } })
    end
    assert_includes err.message, "providers.openai"
  end

  def test_a_user_declared_as_a_string_is_rejected
    err = assert_raises(Riggs::Error) { merge({ users: { matt: { role: "pm" } } }, { users: { matt: "pm" } }) }
    assert_includes err.message, "users.matt"
  end

  def test_an_mcp_server_declared_as_a_string_is_rejected
    err = assert_raises(Riggs::Error) do
      merge({ mcp_servers: { hb: { command: "npx" } } }, { mcp_servers: { hb: "npx" } })
    end
    assert_includes err.message, "mcp_servers.hb"
  end

  def test_a_section_that_is_not_a_mapping_is_rejected
    err = assert_raises(Riggs::Error) { merge({ providers: { openai: {} } }, { providers: "everything" }) }
    assert_includes err.message, "providers"
    assert_includes err.message, "mapping"
  end

  # The guard above must not over-tighten. A role maps to a LIST of
  # permissions -- Identity::DEFAULT_ROLES values are Arrays -- so requiring
  # every section's entries to be mappings would reject every legitimate
  # roles: block in existence. This test is why that did not ship.
  def test_a_role_is_still_a_list_of_permissions_and_is_not_rejected
    result = merge({ roles: { pm: ["publish"] } }, { roles: { reviewer: %w[read_workflow inspect_run] } })
    assert_equal %w[read_workflow inspect_run], result.config[:roles][:reviewer]
    assert_equal :project, result.provenance[:roles][:reviewer]
  end

  def test_a_role_declared_as_a_bare_string_is_rejected
    err = assert_raises(Riggs::Error) { merge({ roles: {} }, { roles: { reviewer: "read_workflow" } }) }
    assert_includes err.message, "roles.reviewer"
    assert_includes err.message, "list"
  end

  # --- pricing is billing truth, and billing truth is the operator's ---
  #
  # A project setting its own pricing could report $0.00 for a run that cost
  # $60.00. Verified before this guard. riggs exists to tell the operator what
  # their agents cost, so a repository that can rewrite that number defeats
  # the product, not merely a control.
  def test_pricing_in_the_project_tier_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({ providers: { claude: { type: "anthropic" } } },
            { providers: { claude: { pricing: { "claude-x" => { "input" => 0.0, "output" => 0.0 } } } } })
    end
    assert_includes err.message, "pricing"
    assert_includes err.message, "claude"
  end

  # --- the endpoint is the operator's too ---
  #
  # Trust is granted once; a repository's config stays mutable afterwards.
  # A repo trusted while benign could later point a globally configured
  # provider at its own host, and OpenAICompatible would send the operator's
  # OPENAI_API_KEY there as a bearer token -- no api_key field, no re-prompt,
  # because only MCP approvals re-verify when they change. Naming the
  # destination is as good as naming the credential.
  def test_base_url_in_the_project_tier_is_a_hard_error
    err = assert_raises(Riggs::Error) do
      merge({ providers: { openai: { type: "openai" } } },
            { providers: { openai: { base_url: "https://attacker.invalid/v1" } } })
    end
    assert_includes err.message, "base_url"
    assert_includes err.message, "openai"
  end

  # What a project may still do: choose the model, the chain and the auth
  # mode. Not where the traffic goes, not what it costs, not the credential.
  def test_a_project_may_still_retune_model_relay_chain_and_auth
    result = merge(
      { providers: { ollama: { type: "ollama", base_url: "http://operator-chosen" } } },
      { providers: { ollama: { model: "llama3.2", relay_chain: %w[ollama mock], auth: "none" } } }
    )
    assert_equal "llama3.2", result.config[:providers][:ollama][:model]
    assert_equal %w[ollama mock], result.config[:providers][:ollama][:relay_chain]
    assert_equal "http://operator-chosen", result.config[:providers][:ollama][:base_url]
  end

  # --- the tier itself must be a mapping ---
  #
  # ProjectShape checks each SECTION's shape. The document holding those
  # sections was still unchecked, so a top-level scalar reached .keys as a
  # NoMethodError instead of a configuration error.

  def test_a_project_tier_that_is_not_a_mapping_is_a_configuration_error
    err = assert_raises(Riggs::Error) { merge({}, "not-a-mapping") }
    assert_includes err.message, P
    assert_includes err.message, "mapping"
  end

  # `false` is not nil: it must not be silently indistinguishable from
  # "this repository has no project tier".
  def test_a_project_tier_of_false_is_a_configuration_error_not_an_empty_tier
    assert_raises(Riggs::Error) { merge({}, false) }
  end

  def test_a_global_tier_that_is_not_a_mapping_is_a_configuration_error
    err = assert_raises(Riggs::Error) { merge("nope", {}) }
    assert_includes err.message, G
  end

  def test_a_nil_tier_is_still_an_absent_tier
    result = merge(nil, nil)
    assert_empty result.config
  end
end

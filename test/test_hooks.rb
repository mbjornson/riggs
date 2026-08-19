# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestHooks < Minitest::Test
  def test_fire_runs_handlers_in_order_and_mutates_context
    hooks = Riggs::Hooks.new
    order = []
    hooks.on(:before_provider_request) do |ctx|
      order << :a
      ctx[:system] = "#{ctx[:system]}|a"
    end
    hooks.on(:before_provider_request) do |ctx|
      order << :b
      ctx[:system] = "#{ctx[:system]}|b"
    end

    out = hooks.fire(:before_provider_request, { system: "base", messages: [] })
    assert_equal %i[a b], order
    assert_equal "base|a|b", out[:system]
  end

  def test_tool_call_deny_stops_chain
    hooks = Riggs::Hooks.new
    hooks.on(:tool_call) { |ctx| ctx[:deny] = "blocked" }
    hooks.on(:tool_call) { |_ctx| flunk "second handler must not run after deny" }

    out = hooks.fire(:tool_call, { name: "x", arguments: {} })
    assert_equal "blocked", out[:deny]
  end

  def test_tool_call_can_mutate_arguments
    hooks = Riggs::Hooks.new
    hooks.on(:tool_call) do |ctx|
      ctx[:arguments] = ctx[:arguments].merge(topic: "mutated")
    end

    out = hooks.fire(:tool_call, { name: "lookup_runbook", arguments: { topic: "orig" } })
    assert_equal "mutated", out[:arguments][:topic]
  end

  def test_tool_result_can_rewrite_output
    hooks = Riggs::Hooks.new
    hooks.on(:tool_result) { |ctx| ctx[:result] = "rewritten:#{ctx[:result]}" }

    out = hooks.fire(:tool_result, { name: "t", result: "raw" })
    assert_equal "rewritten:raw", out[:result]
  end

  def test_default_rbac_denies_mcp_tool_without_manage_mcp
    identity = {
      id: "runner",
      role: :custom,
      permissions: %w[run_workflow]
    }
    hooks = Riggs::Hooks.default(identity: identity)
    out = hooks.fire(:tool_call, {
                       name: "evil_tool",
                       arguments: {},
                       builtin: false
                     })
    assert out[:deny], "MCP tool must be denied without manage_mcp"
  end

  def test_default_rbac_allows_builtin_without_manage_mcp
    identity = {
      id: "runner",
      role: :custom,
      permissions: %w[run_workflow]
    }
    hooks = Riggs::Hooks.default(identity: identity)
    out = hooks.fire(:tool_call, {
                       name: "lookup_runbook",
                       arguments: { topic: "x" },
                       builtin: true
                     })
    refute out[:deny]
  end

  def test_host_can_deny_tool_by_role_without_patching_tool_loop
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      workflow[:steps].first.input.replace(
        "Please lookup runbook for this ticket: {{workflow.input.ticket}}"
      )

      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      hooks = Riggs::Hooks.default(identity: identity)
      hooks.on(:tool_call) do |ctx|
        ctx[:deny] = "role policy: engineers may not call lookup_runbook" if ctx[:name].to_s == "lookup_runbook"
      end

      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
        gate_handler: ->(*) { :approved },
        hooks: hooks
      )
      engine.execute(StringIO.new, input: { ticket: "Password reset request" })
      assert_equal :completed, engine.status

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      tool_rows = storage.list_messages(engine.session_id).select { |r| r["role"] == "tool" }
      storage.close
      assert tool_rows.any? { |r| r["content"].to_s.start_with?("TOOL_DENIED:") },
             "expected TOOL_DENIED in tool results, got: #{tool_rows.map { |r| r['content'] }}"
    end
  end

  def test_builtin_lookup_runbook_still_works_via_registry
    assert_match(/Runbook\[auth\]/, Riggs::BuiltinTools.call("lookup_runbook", { topic: "auth" }))
    assert_nil Riggs::BuiltinTools.call("nope", {})
  end

  def test_merge_appends_other_handlers_per_event
    left = Riggs::Hooks.new
    right = Riggs::Hooks.new
    order = []
    left.on(:tool_result) { order << :left }
    right.on(:tool_result) { order << :right }

    left.merge!(right)
    left.fire(:tool_result, { result: "x" })

    assert_equal %i[left right], order
  end

  def test_default_with_nil_identity_denies_non_builtin_tools
    hooks = Riggs::Hooks.default(identity: nil)
    out = hooks.fire(:tool_call, { name: "evil_tool", arguments: {}, builtin: false })

    assert out[:deny], "Hooks.default(identity: nil) must deny MCP tools (fail closed)"
  end

  def test_default_with_nil_identity_still_allows_builtins
    hooks = Riggs::Hooks.default(identity: nil)
    out = hooks.fire(:tool_call, { name: "lookup_runbook", arguments: { topic: "x" }, builtin: true })

    refute out[:deny]
  end

  def test_permitted_is_false_when_identity_is_nil
    refute Riggs::Identity.permitted?(nil, "manage_mcp")
  end

  def test_permitted_is_false_when_permissions_are_missing
    refute Riggs::Identity.permitted?({ id: "x", role: :custom }, "manage_mcp")
  end

  def test_custom_log_only_hook_does_not_allow_mcp_without_manage_mcp
    with_tmp_project do
      logged = []
      custom = Riggs::Hooks.new
      custom.on(:tool_call) { |ctx| logged << ctx[:name] }

      identity = {
        id: "runner",
        role: :custom,
        permissions: %w[run_workflow],
        memory_namespace: "test"
      }
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
        hooks: custom
      )

      out = engine.instance_variable_get(:@hooks).fire(:tool_call, {
                                                         name: "evil_tool",
                                                         arguments: {},
                                                         builtin: false
                                                       })
      assert out[:deny],
             "a custom log-only hook must not replace the default MCP deny"
    end
  end
end

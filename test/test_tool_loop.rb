# frozen_string_literal: true

require "test_helper"
require "stringio"
require "json"

class TestToolLoop < Minitest::Test
  def test_mock_tool_call_then_final
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      # Force classify step to request a lookup so Mock emits tool_calls
      workflow[:steps].first.input.replace(
        "Please lookup runbook for this ticket: {{workflow.input.ticket}}"
      )

      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      io = StringIO.new
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: identity,
        db_path: "./db/riggs.sqlite3",
        hub_config: Riggs::Identity.load_config,
        skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
        gate_handler: ->(*) { :approved }
      )

      engine.execute(io, input: { ticket: "Password reset request" })
      assert_equal :completed, engine.status
      assert engine.llm_calls >= 2, "expected tool loop to make >= 2 LLM calls, got #{engine.llm_calls}"
      events = engine.audit_log.map { |e| e[:event_type] }
      assert_includes events, "tool_call"
      assert_includes events, "tool_result"
      assert_match(/classification=OK|used_tool|lookup/i, engine.outputs[:classification].to_s)
    end
  end

  def test_tool_calling_step_persists_tool_calls_and_matching_tool_result
    with_tmp_project do
      engine = tool_calling_engine
      engine.execute(StringIO.new, input: { ticket: "Password reset request" })
      assert_equal :completed, engine.status

      storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
      rows = storage.list_messages(engine.session_id, step_key: "classify")

      assert_equal %w[user assistant tool assistant], rows.map { |r| r["role"] }
      assert_nil rows[0]["tool_calls"], "the user turn carries no tool_calls"

      requesting = rows[1]
      refute_nil requesting["tool_calls"], "the assistant turn requesting tools must store them"
      assert_equal "mock", requesting["provider"]
      calls = JSON.parse(requesting["tool_calls"])
      assert_equal 1, calls.size
      assert_equal "lookup_runbook", calls.first["name"]

      tool_row = rows[2]
      assert_equal calls.first["id"], tool_row["tool_call_id"], "tool result must reference its call id"
      assert_equal "lookup_runbook", tool_row["tool_name"]
      assert_match(/Runbook/, tool_row["content"])
      assert_nil tool_row["provider"], "tool results are not produced by a provider"
      storage.close
    end
  end

  def test_persist_defaults_to_nil_and_disables_persistence
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })
    step = Riggs::Workflow::StepNode.from_hash("id" => "solo", "input" => "hello")

    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router,
      mcp_manager: nil,
      skill_registry: nil,
      audit: ->(**_kwargs) {},
      llm_calls: 0,
      max_llm_calls: 5,
      timeout_seconds: 30,
      started_at: Time.now,
      session_id: "no-session"
    )

    outcome = loop_runner.run(
      step: step,
      chain: ["mock"],
      messages: [{ role: "user", content: "hello" }],
      system_prompt: "test",
      io: StringIO.new
    )

    assert_equal "mock", outcome[:provider]
    refute_empty outcome[:content], "a loop without a persist callback still returns its answer"
  end

  def test_records_one_provider_call_per_turn
    recorded = []
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })
    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil,
      audit: ->(**) {}, record_call: ->(**kw) { recorded << kw },
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )

    loop_runner.run(step: build_step, chain: ["mock"], messages: [{ role: "user", content: "hello" }],
                    system_prompt: "sys", io: StringIO.new)

    assert_equal 1, recorded.length
    assert_equal "triage", recorded.first[:step_key]
    refute_nil recorded.first[:usage]
    assert_equal 1, recorded.first[:relay_attempt]
  end

  def flaky_provider
    Class.new(Riggs::Providers::Base) do
      def complete(**)
        raise Riggs::Providers::TimeoutError, "read timeout"
      end
    end
  end

  # Router only rescues its own error family, so an unexpected exception
  # propagates without failing over -- correct, but the attempt was still
  # dispatched and still spent. It has to be ledgered on the way out.
  def test_an_unexpected_provider_exception_still_records_its_attempt
    recorded = []
    exploding = Class.new(Riggs::Providers::Base) do
      def complete(**)
        raise "kaboom"
      end
    end
    router = Riggs::Providers::Router.new(
      hub_providers: { boom: { type: "boom" } }, registry: { "boom" => exploding }
    )
    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil,
      audit: ->(**) {}, record_call: ->(**kw) { recorded << kw },
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )

    assert_raises(RuntimeError) do
      loop_runner.run(step: build_step, chain: ["boom"], messages: [{ role: "user", content: "hi" }],
                      system_prompt: "sys", io: StringIO.new)
    end

    assert_equal 1, recorded.length, "an unexpected failure is still a dispatched call"
    refute recorded.first[:usage][:measured]
  end

  # A provider that accepted the request, billed for it, then timed out on the
  # read is spend. Metering only the successful attempt let session coverage
  # report "1 of 1 measured" over a denominator that had already dropped the
  # failure -- the exact overstatement nil-not-zero exists to prevent.
  def test_a_failed_provider_attempt_is_recorded_as_an_unmeasured_call
    recorded = []
    router = Riggs::Providers::Router.new(
      hub_providers: { flaky: { type: "flaky" }, mock: { type: "mock" } },
      registry: { "flaky" => flaky_provider, "mock" => Riggs::Providers::Mock }
    )
    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil,
      audit: ->(**) {}, record_call: ->(**kw) { recorded << kw },
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )

    loop_runner.run(step: build_step, chain: %w[flaky mock], messages: [{ role: "user", content: "hello" }],
                    system_prompt: "sys", io: StringIO.new)

    assert_equal 2, recorded.length, "both the failed attempt and the answering one are calls"
    failed = recorded.find { |r| r[:provider] == "flaky" }
    refute_nil failed, "the failed attempt must reach the ledger"
    refute failed[:usage][:measured], "a failed attempt reports no tokens, and says so"
    assert_nil failed[:cost_usd]
    assert_equal 1, failed[:relay_attempt]
  end

  def test_a_chain_that_fails_entirely_still_records_its_attempts
    recorded = []
    router = Riggs::Providers::Router.new(
      hub_providers: { flaky: { type: "flaky" } },
      registry: { "flaky" => flaky_provider }
    )
    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil,
      audit: ->(**) {}, record_call: ->(**kw) { recorded << kw },
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )

    assert_raises(Riggs::Providers::Error) do
      loop_runner.run(step: build_step, chain: ["flaky"], messages: [{ role: "user", content: "hello" }],
                      system_prompt: "sys", io: StringIO.new)
    end

    assert_equal 1, recorded.length, "a chain that fails entirely still spent the attempt"
    refute recorded.first[:usage][:measured]
  end

  def compacting_loop(max_llm_calls:, record_call: ->(**) {})
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })
    compactor = Riggs::Workflow::Compactor.new(
      router: router, chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 40
    )
    Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil, audit: ->(**) {},
      record_call: record_call, compactor: compactor, llm_calls: 0,
      max_llm_calls: max_llm_calls, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )
  end

  # max_llm_calls is the run's only hard stop on runaway spend. The
  # summarization call did not increment the counter, so a limit of 1 bought
  # two provider calls and the loop reported one.
  def test_compaction_counts_against_max_llm_calls
    assert_raises(Riggs::WorkflowError) do
      compacting_loop(max_llm_calls: 1).run(
        step: build_step, chain: ["mock"],
        messages: [{ role: "user", content: "x" * 4_000 },
                   { role: "user", content: "y" * 4_000 },
                   { role: "user", content: "z" }],
        system_prompt: "sys", io: StringIO.new
      )
    end
  end

  def test_a_compacted_turn_reports_both_calls_it_made
    outcome = compacting_loop(max_llm_calls: 5).run(
      step: build_step, chain: ["mock"],
      messages: [{ role: "user", content: "x" * 4_000 },
                 { role: "user", content: "y" * 4_000 },
                 { role: "user", content: "z" }],
      system_prompt: "sys", io: StringIO.new
    )

    assert_equal 2, outcome[:llm_calls], "one summarization call plus one answering call"
  end

  def test_runs_without_a_record_call_callable
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })
    loop_runner = Riggs::Workflow::ToolLoop.new(
      router: router, mcp_manager: nil, skill_registry: nil, audit: ->(**) {},
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )

    result = loop_runner.run(step: build_step, chain: ["mock"],
                             messages: [{ role: "user", content: "hello" }],
                             system_prompt: "sys", io: StringIO.new)

    refute_nil result[:content]
  end

  def test_compacts_before_calling_the_provider_when_over_budget
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 200, reserve: 0, keep_recent: 50
    )
    loop_runner = build_loop(compactor: compactor)
    messages = 20.times.map { |i| { role: "user", content: "turn#{i} #{'x' * 200}" } }

    result = loop_runner.run(step: build_step, chain: ["mock"], messages: messages,
                             system_prompt: "sys", io: StringIO.new)

    refute_nil result[:content], "the run completes rather than raising"
    assert_operator messages.length, :<, 20, "the message array was compacted in place"
  end

  def test_audits_context_compacted
    events = []
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 200, reserve: 0, keep_recent: 50
    )
    loop_runner = build_loop(compactor: compactor, audit: ->(**kw) { events << kw })

    loop_runner.run(step: build_step, chain: ["mock"],
                    messages: 20.times.map { |i| { role: "user", content: "t#{i} #{'x' * 200}" } },
                    system_prompt: "sys", io: StringIO.new)

    compaction = events.find { |e| e[:event_type] == "context_compacted" }

    refute_nil compaction
    assert_operator compaction[:payload][:after], :<, compaction[:payload][:before]
  end

  # Riggs::Usage normalizes input_tokens to UNCACHED input -- correct for
  # pricing, wrong for sizing. OpenAI caches any prompt over 1024 tokens
  # automatically, so on a long transcript the vendor reports a small
  # input_tokens for a huge prompt. Anchoring on that number sizes the request
  # at a fraction of what was really sent and over_budget? never fires, which
  # is precisely the runaway growth compaction exists to prevent.
  def test_anchors_on_the_whole_prompt_when_the_vendor_served_it_from_cache
    events = []
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 100_000, reserve: 10_000, keep_recent: 1
    )
    loop_runner = build_loop(compactor: compactor, audit: ->(**kw) { events << kw },
                             router: cached_prompt_router)

    loop_runner.run(step: build_step, chain: ["mock"], messages: [{ role: "user", content: "hi" }],
                    system_prompt: "sys", io: StringIO.new)

    assert(events.any? { |e| e[:event_type] == "context_compacted" },
           "a 100k prompt reported as 5k uncached + 95k cached is over a 90k ceiling; " \
           "anchoring on input_tokens alone hides that entirely")
  end

  # A transcript that cannot be split (one oversized message) is still over
  # budget after compaction runs. The event must say so: an operator reading
  # `strategy: "summarized", before: 1000, after: 1000, collapsed: 0` sees
  # compaction working while the request is over budget and unchanged.
  # The event is deliberately still emitted -- suppressing it would recreate
  # the silent non-compaction R3.5 exists to make visible.
  def test_audits_a_noop_compaction_as_such
    events = []
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 100, reserve: 0, keep_recent: 1
    )
    loop_runner = build_loop(compactor: compactor, audit: ->(**kw) { events << kw })

    loop_runner.run(step: build_step, chain: ["mock"],
                    messages: [{ role: "user", content: "x" * 4_000 }],
                    system_prompt: "sys", io: StringIO.new)

    compaction = events.find { |e| e[:event_type] == "context_compacted" }

    refute_nil compaction, "an over-budget turn that could not be reduced must still be visible"
    assert_equal "noop", compaction[:payload][:strategy]
    assert_equal compaction[:payload][:before], compaction[:payload][:after]
    assert_equal 0, compaction[:payload][:collapsed]
  end

  def test_no_compaction_without_a_compactor
    loop_runner = build_loop(compactor: nil)

    result = loop_runner.run(step: build_step, chain: ["mock"],
                             messages: [{ role: "user", content: "hi" }],
                             system_prompt: "sys", io: StringIO.new)

    refute_nil result[:content]
  end

  def test_step_with_its_own_relay_chain_compacts_through_that_chain_not_the_first_steps
    Dir.mktmpdir("riggs-chain-test") do |dir|
      db_path = File.join(dir, "db", "riggs.sqlite3")
      storage = Riggs::Storage.new(db_path: db_path)

      workflow = {
        name: "chain_test",
        context_window: 12,
        reserve_tokens: 0,
        keep_recent_tokens: 1,
        max_llm_calls: 20,
        timeout_seconds: 60,
        providers: {
          default: { relay_chain: ["mock"] },
          special: { relay_chain: ["special_mock"] },
          special_mock: { type: "mock" }
        },
        steps: [
          Riggs::Workflow::StepNode.from_hash(id: "first", input: "hello", output_var: "first", next: "second"),
          Riggs::Workflow::StepNode.from_hash(id: "second", provider: "special",
                                              input: "please lookup runbook now", output_var: "second")
        ]
      }

      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: { id: "test_user", memory_namespace: "test" },
        storage: storage,
        db_path: db_path,
        mcp_manager: lookup_tool_mcp_manager
      )

      engine.execute(StringIO.new, input: {})
      assert_equal :completed, engine.status

      compaction = engine.audit_log.find do |e|
        e[:event_type] == "context_compacted" && e[:payload][:step] == "second"
      end
      refute_nil compaction, "compaction must actually trigger for step 'second' -- " \
                             "otherwise this test proves nothing about which chain it used"

      providers = storage.db.execute(
        "SELECT provider FROM riggs_provider_calls WHERE session_id = ? AND step_key = ?",
        [engine.session_id, "second"]
      ).map { |row| row["provider"] }

      refute_includes providers, "mock",
                      "step 'second' declares its own relay_chain (special_mock); its compaction " \
                      "must not summarize through the first step's chain (mock)"
      assert_includes providers, "special_mock"
    ensure
      storage&.close
    end
  end

  # The regression an adversarial review found on this branch. This exact
  # SKILL.yml loads on main -- aliases were enabled -- with mcp_servers pinned
  # to ["github"], and the step is offered gh_search and nothing else.
  # Disabling aliases makes the file malformed; skip-and-warn turns malformed
  # into nil; and resolve_tools reads nil as "no skill constrains this step",
  # so the step would be handed prod_sql and fs_write from servers the skill
  # never pinned. A pin that disappears when a file fails to parse is not a
  # boundary. The step must not run at all.
  def test_a_step_naming_an_unloadable_skill_is_not_handed_unpinned_tools
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/gh_only")
      File.write("config/riggs/skills/gh_only/SKILL.yml", <<~YAML)
        name: gh_only
        version: "1.0.0"
        defaults: &d
          description: shared
        system_prompt: Only GitHub.
        mcp_servers:
          - github
        tools:
          - name: gh_search
            mcp_server: github
            <<: *d
      YAML
      step = Riggs::Workflow::StepNode.from_hash(
        "id" => "s", "input" => "go", "output_var" => "o", "skill" => "gh_only"
      )

      loop_obj = unloadable_skill_loop
      tools = :never_assigned

      err = assert_raises(Riggs::SkillUnavailable) do
        capture_io { tools = loop_obj.send(:resolve_tools, loop_obj.send(:load_skill, step)) }
      end

      assert_match(/gh_only/, err.message, "the failure must name the skill the step pinned")
      assert_equal :never_assigned, tools,
                   "resolve_tools must never run for a step whose skill could not be loaded"
    end
  end

  # A step that declares a skill but has no registry to resolve it against is
  # in the same position as one whose file will not parse: the pin cannot be
  # enforced. GraphEngine and GraphEngine.resume both default skill_registry
  # to nil, so this is reachable by any embedder constructing the engine
  # directly with an MCP manager.
  def test_a_step_naming_a_skill_with_no_registry_configured_does_not_run
    with_tmp_project do
      step = Riggs::Workflow::StepNode.from_hash(
        "id" => "s", "input" => "go", "output_var" => "o", "skill" => "restricted"
      )
      loop_obj = Riggs::Workflow::ToolLoop.new(
        router: nil, mcp_manager: multi_server_mcp_manager, skill_registry: nil,
        audit: ->(*) {}, llm_calls: 0, max_llm_calls: 5,
        timeout_seconds: 60, started_at: Time.now, session_id: "s1"
      )

      assert_raises(Riggs::SkillUnavailable) { loop_obj.send(:load_skill, step) }
    end
  end

  # `skills:` reached the skill through `.first`, so a stray blank list entry
  # -- a bare "-" in the YAML -- resolved to nil. That did two things at once:
  # unscoped the step, and silently discarded the skill the author actually
  # declared on the next line. The declared skill must win.
  def test_a_blank_first_entry_does_not_discard_the_skill_the_step_declares
    with_tmp_project do
      write_scoped_skill("restricted")
      step = Riggs::Workflow::StepNode.from_hash(
        "id" => "s", "input" => "go", "output_var" => "o",
        "skills" => [nil, "restricted@1.0.0"]
      )
      loop_obj = unloadable_skill_loop

      tools = loop_obj.send(:resolve_tools, loop_obj.send(:load_skill, step))

      assert_equal ["gh_search"], tools.map { |t| t[:name] },
                   "the pinned skill on the second line must scope the step"
    end
  end

  # Declaring a list and putting nothing usable in it is a broken declaration,
  # not a decision to run unscoped.
  def test_a_skills_list_with_no_usable_entry_does_not_run_unscoped
    with_tmp_project do
      step = Riggs::Workflow::StepNode.from_hash(
        "id" => "s", "input" => "go", "output_var" => "o", "skills" => [nil, ""]
      )

      assert_raises(Riggs::SkillUnavailable) { unloadable_skill_loop.send(:load_skill, step) }
    end
  end

  def test_an_empty_skill_name_does_not_run_unscoped
    with_tmp_project do
      step = Riggs::Workflow::StepNode.from_hash(
        "id" => "s", "input" => "go", "output_var" => "o", "skill" => ""
      )

      assert_raises(Riggs::SkillUnavailable) { unloadable_skill_loop.send(:load_skill, step) }
    end
  end

  # An empty `skills: []` is not a declaration -- it is the absence of one, and
  # must keep behaving like a step that never mentioned skills at all.
  def test_an_empty_skills_list_is_not_a_declaration
    with_tmp_project do
      step = Riggs::Workflow::StepNode.from_hash(
        "id" => "s", "input" => "go", "output_var" => "o", "skills" => []
      )
      loop_obj = unloadable_skill_loop

      assert_nil loop_obj.send(:load_skill, step)
    end
  end

  # The step named no skill at all, so there is no pin to lose and nothing to
  # fail closed on. This is the nil that resolve_tools was always allowed to
  # read as "unconstrained", and it must keep working.
  def test_a_step_naming_no_skill_still_runs_with_every_tool
    with_tmp_project do
      step = Riggs::Workflow::StepNode.from_hash("id" => "s", "input" => "go", "output_var" => "o")
      loop_obj = unloadable_skill_loop

      skill = loop_obj.send(:load_skill, step)
      tools = loop_obj.send(:resolve_tools, skill)

      assert_nil skill
      assert_equal %w[gh_search prod_sql fs_write], tools.map { |t| t[:name] }
    end
  end

  # A skill that loads still scopes the step to the servers it pins.
  def test_a_loadable_skill_still_scopes_tools_to_its_pinned_servers
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/gh_only")
      File.write("config/riggs/skills/gh_only/SKILL.yml", <<~YAML)
        name: gh_only
        version: "1.0.0"
        system_prompt: Only GitHub.
        mcp_servers:
          - github
        tools:
          - name: gh_search
            mcp_server: github
            description: Search GitHub.
      YAML
      step = Riggs::Workflow::StepNode.from_hash(
        "id" => "s", "input" => "go", "output_var" => "o", "skill" => "gh_only"
      )
      loop_obj = unloadable_skill_loop

      tools = loop_obj.send(:resolve_tools, loop_obj.send(:load_skill, step))

      assert_equal ["gh_search"], tools.map { |t| t[:name] },
                   "a pinned skill must not see servers it did not list"
    end
  end

  private

  def build_step
    Riggs::Workflow::StepNode.from_hash(
      { "id" => "triage", "agent" => "triager", "input" => "x", "output_var" => "out" }
    )
  end

  def build_loop(compactor: nil, audit: ->(**) {}, router: nil)
    Riggs::Workflow::ToolLoop.new(
      router: router || Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      mcp_manager: nil, skill_registry: nil, audit: audit, compactor: compactor,
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )
  end

  # A router double reporting the OpenAI cached-prompt shape: a 100,000-token
  # prompt of which 95,000 came from cache. Emits one tool call so the loop
  # takes a second turn -- the anchor only exists from the second turn on.
  def cached_prompt_router
    Class.new do
      def initialize
        @calls = 0
      end

      def call(**)
        @calls += 1
        usage = Riggs::Usage.normalize("prompt_tokens" => 100_000, "completion_tokens" => 500,
                                       "prompt_tokens_details" => { "cached_tokens" => 95_000 })
        base = { provider: "fake", model: nil, usage: usage, cost_usd: nil }
        return base.merge(content: "done") if @calls > 1

        base.merge(content: "",
                   tool_calls: [{ id: "t1", name: "lookup_runbook", arguments: { topic: "auth" } }])
      end
    end.new
  end

  # A minimal MCP manager double whose only tool is the "lookup_runbook"
  # built-in ToolLoop stub -- enough to make Mock emit a tool call so a
  # step's transcript grows across multiple turns without needing a real
  # skill/registry fixture.
  def lookup_tool_mcp_manager
    Class.new do
      def list_tools
        [{ name: "lookup_runbook", description: "Look up a runbook", input_schema: {}, server: "local" }]
      end

      def call_tool(*, **)
        "unused -- lookup_runbook is handled by ToolLoop's built-in stub"
      end

      def close; end
    end.new
  end

  def tool_calling_engine
    workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
    # Force the classify step to request a lookup so Mock emits tool_calls
    workflow[:steps].first.input.replace("Please lookup runbook for this ticket: {{workflow.input.ticket}}")

    Riggs::Workflow::GraphEngine.new(
      workflow: workflow,
      user_identity: Riggs::Identity.resolve(cli_user: "eng_bob"),
      db_path: "./db/riggs.sqlite3",
      hub_config: Riggs::Identity.load_config,
      skill_registry: Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"]),
      gate_handler: ->(*) { :approved }
    )
  end

  # An MCP manager advertising one tool the skill pins and two it never
  # mentions, from servers it never lists. If a skill fails to resolve and the
  # step runs anyway, these are what the model is handed.
  def multi_server_mcp_manager
    Class.new do
      def list_tools
        [{ name: "gh_search", description: "Search GitHub", input_schema: {}, server: "github" },
         { name: "prod_sql", description: "Query production", input_schema: {}, server: "postgres_prod" },
         { name: "fs_write", description: "Write a file", input_schema: {}, server: "filesystem" }]
      end

      def call_tool(*, **) = "unused"
      def close; end
    end.new
  end

  # A skill pinned to one server, with one tool on it.
  def write_scoped_skill(name)
    FileUtils.mkdir_p("config/riggs/skills/#{name}")
    File.write("config/riggs/skills/#{name}/SKILL.yml", <<~YAML)
      name: #{name}
      version: "1.0.0"
      system_prompt: Only GitHub.
      mcp_servers:
        - github
      tools:
        - name: gh_search
          mcp_server: github
          description: Search GitHub.
    YAML
  end

  def unloadable_skill_loop(dir: "./config/riggs/skills")
    Riggs::Workflow::ToolLoop.new(
      router: nil, mcp_manager: multi_server_mcp_manager,
      skill_registry: Riggs::SkillRegistry.new(roots: [dir]),
      audit: ->(*) {}, llm_calls: 0, max_llm_calls: 5,
      timeout_seconds: 60, started_at: Time.now, session_id: "s1"
    )
  end
end

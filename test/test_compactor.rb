# frozen_string_literal: true

require_relative "test_helper"

class TestCompactor < Minitest::Test
  def build(budget: 1_000, reserve: 100, keep_recent: 200, overrides: {})
    Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: budget, reserve: reserve, keep_recent: keep_recent,
      model_overrides: overrides
    )
  end

  # Every other test in this file picks its own budget/reserve/keep_recent,
  # which is exactly how `context_window: short` shipped with an effective
  # ceiling of 0 (8,000 budget minus the default 16,384 reserve) and how the
  # default keep_recent (20,000) shipped larger than the default ceiling
  # (32,000 - 16,384 = 15,616), making compaction unable to reach it. These
  # two tests instantiate from Loader's ACTUAL defaults instead.
  def compactor_from_loader_defaults(context_window)
    with_tmp_project do
      config = { "name" => "defaults_test", "context_window" => context_window,
                 "steps" => [{ "id" => "a", "input" => "x", "output_var" => "out" }] }
      File.write("config/riggs/workflows/defaults_test.yml", YAML.dump(config))
      wf = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/defaults_test.yml")
      return Riggs::Workflow::Compactor.new(
        router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
        chain: ["mock"], budget: wf[:context_window],
        reserve: wf[:reserve_tokens], keep_recent: wf[:keep_recent_tokens]
      )
    end
  end

  def test_every_shipped_context_budget_leaves_a_usable_ceiling
    Riggs::Workflow::Loader::CONTEXT_BUDGETS.each_key do |word|
      ceiling = compactor_from_loader_defaults(word.to_s).ceiling(model: nil)

      assert_operator ceiling, :>, 0,
                      "context_window: #{word} with the shipped defaults leaves no room for any message"
    end
  end

  def test_a_transcript_over_the_default_ceiling_compacts_below_it
    compactor = compactor_from_loader_defaults("medium")
    ceiling = compactor.ceiling(model: nil)
    messages = 80.times.map { |i| { role: "user", content: "turn#{i} #{'x' * 2_000}" } }

    assert compactor.over_budget?(messages, model: nil), "test setup: the transcript must start over budget"

    result = compactor.compact(messages: messages, step_key: "s", model: nil)

    assert_operator result[:after], :<, ceiling,
                    "compaction must bring the transcript under the ceiling it was measured against, " \
                    "or the loop re-enters compaction on every turn and never recovers"
  end

  def failing_router
    failing = Object.new
    def failing.call(**) = raise(Riggs::Providers::Error, "boom")
    failing
  end

  def test_ceiling_is_budget_minus_reserve_when_the_model_is_unknown
    assert_equal 900, build.ceiling(model: "unknown-model")
  end

  def test_ceiling_uses_the_model_window_when_it_is_lower
    c = build(budget: 1_000_000, overrides: { "small" => { context_window: 5_000 } })

    assert_equal 4_900, c.ceiling(model: "small")
  end

  def test_ceiling_uses_the_budget_when_the_model_window_is_higher
    c = build(budget: 1_000, overrides: { "big" => { context_window: 500_000 } })

    assert_equal 900, c.ceiling(model: "big")
  end

  def test_over_budget_is_false_for_a_small_transcript
    refute build.over_budget?([{ role: "user", content: "hi" }], model: nil)
  end

  def test_over_budget_is_true_past_the_ceiling
    assert build.over_budget?([{ role: "user", content: "x" * 8_000 }], model: nil)
  end

  def test_compact_keeps_recent_turns_verbatim
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    result = build(keep_recent: 300).compact(messages: messages, step_key: "triage", model: nil)

    assert_operator result[:after], :<, result[:before]
    assert_equal messages.last[:content], result[:messages].last[:content]
    assert_equal "summarized", result[:strategy]
  end

  def test_compact_inserts_exactly_one_summary_turn
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    result = build(keep_recent: 300).compact(messages: messages, step_key: "triage", model: nil)
    summaries = result[:messages].select { |m| m[:compacted] }

    assert_equal 1, summaries.length
    assert_equal "assistant", summaries.first[:role]
  end

  # A tool result without its originating assistant turn is a malformed
  # transcript that providers reject.
  def test_compact_never_orphans_tool_results
    messages = [
      { role: "user", content: "x" * 2_000 },
      { role: "assistant", content: "", tool_calls: [{ id: "t1", name: "lookup", arguments: {} }] },
      { role: "tool", tool_call_id: "t1", name: "lookup", content: "y" * 100 },
      { role: "assistant", content: "done" }
    ]

    kept = build(keep_recent: 60).compact(messages: messages, step_key: "s", model: nil)[:messages]
    tool_turns = kept.select { |m| m[:role] == "tool" }

    tool_turns.each do |t|
      assert(kept.any? { |m| Array(m[:tool_calls]).any? { |tc| tc[:id] == t[:tool_call_id] } },
             "tool result #{t[:tool_call_id]} was kept without its assistant turn")
    end
  end

  # The test above (keep_recent: 60) never actually forces the naive backward
  # walk to stop ON the tool turn -- with these four messages it always
  # overshoots straight past the pair to the big leading user turn, so
  # safe_boundary's own walk-back never runs; the test would pass even with
  # safe_boundary deleted entirely (verified by hand-tracing Usage.heuristic
  # against each candidate). keep_recent: 30 lands the naive split exactly on
  # the tool turn (kept sums to 26 after the tool turn, 37 after the
  # assistant+tool_calls turn before it -- 30 sits between the two), so this
  # is the case that actually exercises safe_boundary's correction.
  def test_compact_never_orphans_tool_results_when_the_naive_boundary_lands_on_the_tool_turn
    messages = [
      { role: "user", content: "x" * 2_000 },
      { role: "assistant", content: "", tool_calls: [{ id: "t1", name: "lookup", arguments: {} }] },
      { role: "tool", tool_call_id: "t1", name: "lookup", content: "y" * 100 },
      { role: "assistant", content: "done" }
    ]

    kept = build(keep_recent: 30).compact(messages: messages, step_key: "s", model: nil)[:messages]
    tool_turns = kept.select { |m| m[:role] == "tool" }

    refute_empty tool_turns, "test setup should still retain the tool turn in the kept set"
    tool_turns.each do |t|
      assert(kept.any? { |m| Array(m[:tool_calls]).any? { |tc| tc[:id] == t[:tool_call_id] } },
             "tool result #{t[:tool_call_id]} was kept without its assistant turn")
    end
  end

  # split_index's while loop decrements idx to 0 without ever breaking when
  # everything already fits inside keep_recent. compact must treat that as
  # "nothing to do" rather than collapsing the whole transcript into a
  # zero-length "recent" (which is what a naive off-by-one would do with an
  # idx of 0 meaning "split at the very start, keep nothing").
  def test_compact_is_a_no_op_when_everything_already_fits
    messages = [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }]

    result = build(keep_recent: 10_000).compact(messages: messages, step_key: "s", model: nil)

    assert_equal messages, result[:messages]
    assert_equal result[:before], result[:after]
    assert_equal 0, result[:collapsed]
    assert_equal "noop", result[:strategy],
                 "a do-nothing pass must not be reported as a successful summarization"
  end

  # A single oversized message can never be split, so an irreducible transcript
  # reaches compact and comes back unchanged. Reporting that as "summarized" is
  # what an operator sees while the request is still over budget.
  def test_compact_reports_noop_for_an_irreducible_transcript
    messages = [{ role: "user", content: "x" * 40_000 }]

    result = build(keep_recent: 1).compact(messages: messages, step_key: "s", model: nil)

    assert_equal "noop", result[:strategy]
    assert_equal 0, result[:collapsed]
    assert_equal result[:before], result[:after]
  end

  def test_compact_truncates_when_summarization_fails
    events = []
    compactor = Riggs::Workflow::Compactor.new(
      router: failing_router, chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 200,
      audit: ->(**kw) { events << kw }
    )
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    result = compactor.compact(messages: messages, step_key: "s", model: nil)

    assert_equal "truncated", result[:strategy]
    assert_operator result[:messages].length, :<, messages.length
  end

  # This branch already shipped one bug of exactly this class: the omitted
  # session_id below caused a foreign-key failure that the blanket rescue
  # swallowed, degrading every real compaction to truncation with nothing in
  # the stream to say so. An intentional degrade and an unexpected failure must
  # not look identical.
  def test_a_rescued_summarization_failure_names_the_exception
    events = []
    compactor = Riggs::Workflow::Compactor.new(
      router: failing_router, chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 200,
      audit: ->(**kw) { events << kw }, session_id: "sess-1"
    )
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    compactor.compact(messages: messages, step_key: "s", model: nil)
    degraded = events.find { |e| e[:event_type] == "compaction_degraded" }

    refute_nil degraded, "a swallowed summarization failure must be visible somewhere"
    assert_equal "sess-1", degraded[:session_id]
    assert_equal "Riggs::Providers::Error", degraded[:payload][:error]
    assert_match(/boom/, degraded[:payload][:message])
  end

  def test_a_rescued_summarization_failure_warns_when_no_audit_is_wired
    compactor = Riggs::Workflow::Compactor.new(
      router: failing_router, chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 200
    )
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    _out, err = capture_io { compactor.compact(messages: messages, step_key: "s", model: nil) }

    assert_match(/Riggs::Providers::Error/, err)
    assert_match(/boom/, err)
  end

  def test_summarization_call_is_recorded
    recorded = []
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 200,
      record_call: ->(**kw) { recorded << kw }
    )
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    compactor.compact(messages: messages, step_key: "triage", model: nil)

    assert_equal 1, recorded.length
    assert_equal "triage", recorded.first[:step_key],
                 "compaction cost is attributed to the step that triggered it"
  end

  # summarize's rescue must cover only the router call. record_call: is
  # caller-supplied (Task 11/12 wiring); a bug in it is not a summarization
  # failure and must not be disguised as strategy: "truncated" -- the tokens
  # were genuinely spent on a successful LLM call, and hiding that violates
  # the "must not hide the tokens it spent" requirement.
  def test_a_failing_record_call_is_not_disguised_as_a_summarization_failure
    compactor = Riggs::Workflow::Compactor.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 200,
      record_call: ->(**) { raise "record_call bug" }
    )
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    error = assert_raises(RuntimeError) do
      compactor.compact(messages: messages, step_key: "s", model: nil)
    end
    assert_equal "record_call bug", error.message
  end

  # An assistant turn commonly emits more than one tool_calls entry, each
  # answered by its own tool turn -- so multiple CONSECUTIVE tool turns is
  # the common real-world shape, not an edge case. safe_boundary must walk
  # back past all of them, not just one, or the turn in the middle gets
  # orphaned. keep_recent: 40 is sized (verified by hand-tracing
  # Usage.heuristic) so the naive split lands index 3 -- squarely between
  # the two tool turns -- before safe_boundary's correction.
  # GraphEngine always builds its production Router with a real audit:
  # callback wired to storage (audit: ->(**kwargs) { @storage.audit(**kwargs) }).
  # Storage#audit serializes a nil session_id to "" (via utf8), which fails
  # the riggs_audit -> riggs_sessions foreign key the moment the summarization
  # call succeeds and Router#call tries to record "provider_success". Without
  # session_id: threaded through to that call, the exception is silently
  # rescued by call_router and every real compaction degrades to "truncated"
  # -- losing context with no summary and no recorded token cost, even though
  # nothing in the test suite (which never wires a real audit: callback) can
  # see it happen.
  def test_summarizes_instead_of_truncating_when_the_router_audit_is_wired_to_real_storage
    Dir.mktmpdir("riggs-compactor-audit") do |dir|
      db_path = File.join(dir, "db", "riggs.sqlite3")
      storage = Riggs::Storage.new(db_path: db_path)
      session_id = storage.create_session(workflow_name: "wf", user_id: "u", memory_namespace: "ns")

      router = Riggs::Providers::Router.new(
        hub_providers: { mock: { type: "mock" } },
        audit: ->(**kwargs) { storage.audit(**kwargs) }
      )
      compactor = Riggs::Workflow::Compactor.new(
        router: router, chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 200,
        session_id: session_id,
        record_call: ->(**kw) { storage.record_provider_call(session_id: session_id, **kw) }
      )
      messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

      result = compactor.compact(messages: messages, step_key: "s", model: nil)

      assert_equal "summarized", result[:strategy],
                   "a real audit-wired Router must not silently degrade compaction to truncation"
      rows = storage.db.execute(
        "SELECT COUNT(*) AS n FROM riggs_provider_calls WHERE session_id = ? AND step_key = ?", [session_id, "s"]
      )
      assert_equal 1, rows.first["n"], "the summarization call must be recorded"
      storage.close
    end
  end

  def test_compact_never_orphans_tool_results_across_multiple_consecutive_tool_turns
    messages = [
      { role: "user", content: "x" * 2_000 },
      { role: "assistant", content: "",
        tool_calls: [{ id: "t1", name: "lookup", arguments: {} }, { id: "t2", name: "search", arguments: {} }] },
      { role: "tool", tool_call_id: "t1", name: "lookup", content: "y" * 100 },
      { role: "tool", tool_call_id: "t2", name: "search", content: "z" * 100 },
      { role: "assistant", content: "done" }
    ]

    kept = build(keep_recent: 40).compact(messages: messages, step_key: "s", model: nil)[:messages]
    tool_turns = kept.select { |m| m[:role] == "tool" }

    assert_equal 2, tool_turns.length, "test setup should keep both tool turns in the recent set"
    tool_turns.each do |t|
      assert(kept.any? { |m| Array(m[:tool_calls]).any? { |tc| tc[:id] == t[:tool_call_id] } },
             "tool result #{t[:tool_call_id]} was kept without its assistant turn")
    end
  end

  # A summarization call is a real provider call. Reporting it lets the caller
  # charge it against max_llm_calls, which is the run's only runaway-spend stop.
  def recording_router(calls)
    router = Object.new
    router.define_singleton_method(:call) do |**kwargs|
      calls << kwargs
      { provider: "mock", model: nil, content: "summary", usage: {}, cost_usd: nil }
    end
    router
  end

  def compactor_with(router, keep_recent: 40)
    Riggs::Workflow::Compactor.new(router: router, chain: ["mock"], budget: 1_000,
                                   reserve: 100, keep_recent: keep_recent)
  end

  def long_messages
    [{ role: "user", content: "x" * 4_000 }, { role: "user", content: "y" * 100 }]
  end

  def test_compact_reports_the_llm_call_it_made
    calls = []
    result = compactor_with(recording_router(calls)).compact(messages: long_messages, step_key: "s", model: nil)

    assert_equal 1, calls.length, "test setup: this transcript must trigger a summarization call"
    assert_equal 1, result[:llm_calls]
  end

  def test_compact_reports_no_llm_call_when_it_does_nothing
    result = compactor_with(recording_router([])).compact(
      messages: [{ role: "user", content: "tiny" }], step_key: "s", model: nil
    )

    assert_equal "noop", result[:strategy], "test setup: this transcript must not need compacting"
    assert_equal 0, result[:llm_calls]
  end

  # A degraded summarization still spent wall-clock and may have spent tokens.
  def test_compact_reports_the_llm_call_even_when_summarization_fails
    result = compactor_with(failing_router).compact(messages: long_messages, step_key: "s", model: nil)

    assert_equal "truncated", result[:strategy]
    assert_equal 1, result[:llm_calls]
  end

  # The summarization call hardcoded a 60-second timeout, so a compaction that
  # started one second before the run's deadline could run a further minute.
  def test_compact_passes_the_callers_timeout_to_the_summarization_call
    calls = []
    compactor_with(recording_router(calls)).compact(messages: long_messages, step_key: "s",
                                                    model: nil, timeout: 7)

    assert_equal 7, calls.first[:timeout]
  end

  def test_compact_falls_back_to_its_own_timeout_when_the_caller_gives_none
    calls = []
    compactor_with(recording_router(calls)).compact(messages: long_messages, step_key: "s", model: nil)

    assert_operator calls.first[:timeout], :>, 0
  end

  # The summarization call runs through a relay chain like any other, so its
  # failed attempts are spend too. Only ToolLoop's own call reported them.
  def test_compaction_records_its_own_failed_relay_attempts
    recorded = []
    flaky = Class.new(Riggs::Providers::Base) do
      def complete(**)
        raise Riggs::Providers::TimeoutError, "read timeout"
      end
    end
    router = Riggs::Providers::Router.new(
      hub_providers: { flaky: { type: "flaky" }, mock: { type: "mock" } },
      registry: { "flaky" => flaky, "mock" => Riggs::Providers::Mock }
    )
    compactor = Riggs::Workflow::Compactor.new(
      router: router, chain: %w[flaky mock], budget: 1_000, reserve: 100,
      keep_recent: 40, record_call: ->(**kw) { recorded << kw }
    )

    compactor.compact(messages: long_messages, step_key: "step-a", model: nil)

    failed = recorded.find { |r| r[:provider] == "flaky" }
    refute_nil failed, "a compaction's failed relay attempt is a call that happened"
    refute failed[:usage][:measured]
    assert_equal "step-a", failed[:step_key]
  end
end

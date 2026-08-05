# frozen_string_literal: true

require_relative "../usage"
require_relative "../model_info"

module Riggs
  module Workflow
    # Keeps a message array under a token ceiling by replacing older turns with
    # a single summary. Shared by both growth sites: the cross-step history in
    # GraphEngine and the intra-step transcript in ToolLoop.
    class Compactor
      SUMMARY_PROMPT = "Summarize the conversation below in at most 200 words. " \
                       "Preserve decisions, tool results, and any identifiers. " \
                       "Write it as a factual record, not a reply."

      # Only used when a caller supplies no remaining-budget timeout of its own.
      DEFAULT_SUMMARY_TIMEOUT = 60

      def initialize(router:, chain:, budget:, reserve:, keep_recent:,
                     model_overrides: {}, record_call: nil, audit: nil, session_id: nil)
        @router = router
        @chain = chain
        @budget = budget.to_i
        @reserve = reserve.to_i
        @keep_recent = keep_recent.to_i
        @model_overrides = model_overrides || {}
        @record_call = record_call
        # Optional: reports a rescued summarization failure (see #report_degrade).
        # Without it those land on stderr instead.
        @audit = audit
        # Threaded into the summarization call's own @router.call so a
        # real (storage-backed) Router audit callback can find the session
        # this compaction belongs to -- a nil session_id serializes to "" in
        # Storage#audit, which fails the riggs_audit -> riggs_sessions
        # foreign key and gets silently swallowed by call_router's rescue,
        # degrading every real compaction to "truncated" (see Task 12 review).
        @session_id = session_id
      end

      # The lower of the workflow budget and the model's own window, less the
      # reserve that absorbs estimation error.
      def ceiling(model:)
        limit = limit_for(model)
        [limit - reserve_for(limit), 0].max
      end

      def over_budget?(messages, model:, anchor: nil, anchored_count: 0)
        Usage.estimate(messages, anchor: anchor, anchored_count: anchored_count) > ceiling(model: model)
      end

      # `timeout` is the caller's REMAINING budget. Summarization used to
      # hardcode 60 seconds, so a compaction starting one second before a run's
      # deadline could run a further minute past it.
      def compact(messages:, step_key:, model:, timeout: nil)
        list = Array(messages)
        before = Usage.estimate(list)
        split = split_index(list, keep_recent_for(model))
        return no_op(list, before) if split <= 0

        older = list[0...split]
        recent = list[split..] || []
        @llm_calls = 0
        summary = summarize(older, step_key: step_key, timeout: timeout)

        kept = summary ? [summary_turn(summary)] + recent : recent
        { messages: kept, strategy: summary ? "summarized" : "truncated",
          before: before, after: Usage.estimate(kept), collapsed: older.length,
          llm_calls: @llm_calls }
      end

      private

      def limit_for(model)
        window = ModelInfo.context_window(model, overrides: @model_overrides)
        window ? [@budget, window].min : @budget
      end

      # The three knobs are configured independently but have to agree, and
      # absolute defaults borrowed from a ~200k-budget system do not agree with
      # an 8,000-token one: reserve 16,384 against `short` clamps the ceiling to
      # 0, and keep_recent 20,000 against the default 15,616 ceiling means
      # compaction can never reach it. Deriving both from the budget in force
      # makes every budget internally consistent by construction, including
      # budgets that do not exist yet.
      #
      # These clamp CONFIGURED values too. A reserve or keep_recent that breaks
      # the ceiling is not honourable: honouring it produces a workflow that
      # cannot run.
      def reserve_for(limit)
        [@reserve, limit / 4].min
      end

      def keep_recent_for(model)
        [@keep_recent, ceiling(model: model) / 2].min
      end

      # A do-nothing pass -- nothing was old enough to collapse, or the
      # transcript is a single message too big to split. Distinct from
      # "summarized" on purpose: the caller audits this strategy, and a
      # do-nothing pass reported as a successful compaction shows an operator
      # compaction working while the request is over budget and unchanged.
      def no_op(list, before)
        { messages: list, strategy: "noop", before: before, after: before, collapsed: 0,
          llm_calls: 0 }
      end

      # Walks backwards accumulating until keep_recent is reached, then moves
      # the boundary earlier past any leading tool results so an assistant turn
      # is never separated from the tool turns answering it.
      def split_index(list, keep_recent)
        kept = 0
        idx = list.length
        while idx.positive?
          candidate = list[idx - 1]
          kept += Usage.estimate([candidate])
          break if kept > keep_recent && idx < list.length

          idx -= 1
        end
        safe_boundary(list, idx)
      end

      def safe_boundary(list, idx)
        idx -= 1 while idx.positive? && list[idx] && list[idx][:role].to_s == "tool"
        idx
      end

      def summarize(older, step_key:, timeout: nil)
        transcript = older.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n")
        result = call_router(transcript, timeout)
        return nil unless result

        # Outside the rescue deliberately: record_call: is caller-supplied
        # (Task 11/12 wiring), and a bug in it is not a summarization failure.
        # The LLM call above already succeeded and spent real tokens, so a
        # raise here must propagate rather than be reported as "truncated" --
        # that would hide the tokens actually spent.
        record(result, step_key)
        result[:content].to_s
      end

      # Counted before the call, not after: an attempt that raises still spent
      # wall-clock and may have spent tokens on a provider that billed before
      # failing. The caller charges this against max_llm_calls, which is the
      # run's only hard stop on runaway spend.
      def call_router(transcript, timeout = nil)
        @llm_calls = @llm_calls.to_i + 1
        @router.call(
          chain: @chain,
          messages: [{ role: "user", content: "#{SUMMARY_PROMPT}\n\n#{transcript}" }],
          timeout: timeout || DEFAULT_SUMMARY_TIMEOUT,
          session_id: @session_id
        )
      rescue StandardError => e
        # Degrading beats failing: the caller drops the old turns instead. But
        # a silent degrade is indistinguishable from an unexpected one, and
        # this very rescue already hid a real bug once (the omitted session_id
        # whose foreign-key failure degraded every real compaction to
        # truncation, found only by instrumenting the rescue by hand). Always
        # say why.
        report_degrade(e)
        nil
      end

      # Never raises: this runs inside the rescue that keeps compaction
      # degrading rather than failing, so a broken audit: callable must not
      # convert a degrade into a failed run.
      def report_degrade(error)
        payload = { error: error.class.name, message: error.message.to_s[0, 200] }
        return @audit.call(session_id: @session_id, event_type: "compaction_degraded", payload: payload) if @audit

        warn "riggs: compaction summarization failed, truncating instead " \
             "(#{payload[:error]}: #{payload[:message]})"
      rescue StandardError
        nil
      end

      def record(result, step_key)
        @record_call&.call(
          step_key: step_key, provider: result[:provider], model: result[:model],
          relay_attempt: result[:relay_attempt] || 1,
          usage: result[:usage], cost_usd: result[:cost_usd]
        )
      end

      def summary_turn(text)
        { role: "assistant", content: "[compacted summary] #{text}", compacted: true }
      end
    end
  end
end

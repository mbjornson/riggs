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

      def initialize(router:, chain:, budget:, reserve:, keep_recent:,
                     model_overrides: {}, record_call: nil, audit: nil)
        @router = router
        @chain = chain
        @budget = budget.to_i
        @reserve = reserve.to_i
        @keep_recent = keep_recent.to_i
        @model_overrides = model_overrides || {}
        @record_call = record_call
        @audit = audit
      end

      # The lower of the workflow budget and the model's own window, less the
      # reserve that absorbs estimation error.
      def ceiling(model:)
        window = ModelInfo.context_window(model, overrides: @model_overrides)
        limit = window ? [@budget, window].min : @budget
        [limit - @reserve, 0].max
      end

      def over_budget?(messages, model:, anchor: nil, anchored_count: 0)
        Usage.estimate(messages, anchor: anchor, anchored_count: anchored_count) > ceiling(model: model)
      end

      def compact(messages:, step_key:, model:)
        list = Array(messages)
        before = Usage.estimate(list)
        split = split_index(list)
        return no_op(list, before) if split <= 0

        older = list[0...split]
        recent = list[split..] || []
        summary = summarize(older, step_key: step_key)

        kept = summary ? [summary_turn(summary)] + recent : recent
        { messages: kept, strategy: summary ? "summarized" : "truncated",
          before: before, after: Usage.estimate(kept), collapsed: older.length }
      end

      private

      def no_op(list, before)
        { messages: list, strategy: "summarized", before: before, after: before, collapsed: 0 }
      end

      # Walks backwards accumulating until keep_recent is reached, then moves
      # the boundary earlier past any leading tool results so an assistant turn
      # is never separated from the tool turns answering it.
      def split_index(list)
        kept = 0
        idx = list.length
        while idx.positive?
          candidate = list[idx - 1]
          kept += Usage.estimate([candidate])
          break if kept > @keep_recent && idx < list.length

          idx -= 1
        end
        safe_boundary(list, idx)
      end

      def safe_boundary(list, idx)
        idx -= 1 while idx.positive? && list[idx] && list[idx][:role].to_s == "tool"
        idx
      end

      def summarize(older, step_key:)
        transcript = older.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n")
        result = call_router(transcript)
        return nil unless result

        # Outside the rescue deliberately: record_call: is caller-supplied
        # (Task 11/12 wiring), and a bug in it is not a summarization failure.
        # The LLM call above already succeeded and spent real tokens, so a
        # raise here must propagate rather than be reported as "truncated" --
        # that would hide the tokens actually spent.
        record(result, step_key)
        result[:content].to_s
      end

      def call_router(transcript)
        @router.call(
          chain: @chain,
          messages: [{ role: "user", content: "#{SUMMARY_PROMPT}\n\n#{transcript}" }],
          timeout: 60
        )
      rescue StandardError
        # Degrading beats failing: the caller drops the old turns instead.
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

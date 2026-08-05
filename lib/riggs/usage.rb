# frozen_string_literal: true

require "json"

module Riggs
  # Normalizes the assorted vendor `usage` payloads into one shape.
  #
  # Canonical meaning of each field:
  #   input_tokens       uncached prompt tokens
  #   cache_read_tokens  prompt tokens served from cache
  #   cache_write_tokens prompt tokens written to cache
  #   output_tokens      completion tokens
  #
  # Vendors disagree about whether cache reads are included in the prompt
  # count: Anthropic reports them separately, OpenAI reports them as a subset
  # of prompt_tokens. Normalizing to "uncached input" means the OpenAI path
  # subtracts, so total_tokens is comparable across providers.
  module Usage
    EMPTY = {
      input_tokens: nil, output_tokens: nil, cache_read_tokens: nil,
      cache_write_tokens: nil, total_tokens: nil, measured: false
    }.freeze

    CHARS_PER_TOKEN = 4

    # Every prompt-side token the vendor reported, which is what a request is
    # SIZED by -- as opposed to input_tokens, which is uncached input and is
    # what a request is PRICED by. On a cached prompt the two differ by orders
    # of magnitude, so sizing off input_tokens alone under-measures badly.
    #
    # Returns nil, never 0, when no prompt field was reported: nil means "no
    # anchor, estimate the whole array", while 0 would claim the prompt was
    # empty.
    def self.prompt_tokens(usage)
      return nil unless usage.is_a?(Hash)

      parts = [usage[:input_tokens], usage[:cache_read_tokens], usage[:cache_write_tokens]]
      return nil if parts.all?(&:nil?)

      parts.compact.sum(&:to_i)
    end

    # Estimates the token size of a message array that has not been sent yet.
    #
    # `anchor` is the measured prompt size of the most recent response (see
    # .prompt_tokens); `anchored_count` is how many of these messages that
    # prompt contained. Messages beyond that are estimated. The reserve in the
    # compaction ceiling absorbs the error.
    def self.estimate(messages, anchor: nil, anchored_count: 0)
      list = Array(messages)
      return 0 if list.empty?

      if anchor
        tail = list.drop(anchored_count)
        anchor.to_i + heuristic(tail)
      else
        heuristic(list)
      end
    end

    def self.heuristic(messages)
      chars = Array(messages).sum do |m|
        m[:content].to_s.length +
          (m[:tool_calls] ? JSON.generate(m[:tool_calls]).length : 0)
      end
      (chars / CHARS_PER_TOKEN.to_f).ceil
    end

    def self.normalize(raw)
      return EMPTY.dup unless raw.is_a?(Hash) && !raw.empty?

      anthropic?(raw) ? from_anthropic(raw) : from_openai(raw)
    end

    def self.anthropic?(raw)
      !fetch(raw, :input_tokens).nil? || !fetch(raw, :output_tokens).nil? ||
        !fetch(raw, :cache_creation_input_tokens).nil? || !fetch(raw, :cache_read_input_tokens).nil?
    end

    def self.from_anthropic(raw)
      build(
        input: fetch(raw, :input_tokens),
        output: fetch(raw, :output_tokens),
        cache_read: fetch(raw, :cache_read_input_tokens),
        cache_write: fetch(raw, :cache_creation_input_tokens)
      )
    end

    def self.from_openai(raw)
      prompt = fetch(raw, :prompt_tokens)
      details = fetch(raw, :prompt_tokens_details)
      cached = details.is_a?(Hash) ? fetch(details, :cached_tokens) : nil

      build(input: uncached_input(prompt, cached), output: fetch(raw, :completion_tokens),
            cache_read: cached, cache_write: nil)
    end

    # prompt_tokens already contains cached_tokens, so the canonical "uncached
    # input" is the difference. The subtraction is only valid while the vendor
    # honours that contract: a compatible endpoint reporting more cached tokens
    # than prompt tokens (or a negative count) yielded a NEGATIVE input count
    # that storage summed and pricing turned into a credit. An arithmetically
    # impossible reading is not a measurement, so report nil -- the same thing
    # said about a field the vendor never sent. Clamping to 0 would instead
    # claim the prompt was entirely cached, which is a different assertion and
    # one this payload gives no grounds for.
    def self.uncached_input(prompt, cached)
      return nil if prompt.nil?

      cached = cached.to_i
      return nil if cached.negative? || cached > prompt

      prompt - cached
    end

    def self.build(input:, output:, cache_read:, cache_write:)
      parts = [input, output, cache_read, cache_write]
      return EMPTY.dup if parts.all?(&:nil?)

      {
        input_tokens: input, output_tokens: output,
        cache_read_tokens: cache_read, cache_write_tokens: cache_write,
        total_tokens: parts.compact.sum, measured: true
      }
    end

    def self.fetch(hash, key)
      value = hash[key]
      value = hash[key.to_s] if value.nil?
      value
    end

    private_class_method :anthropic?, :from_anthropic, :from_openai, :build, :heuristic,
                         :uncached_input
  end
end

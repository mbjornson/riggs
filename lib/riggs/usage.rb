# frozen_string_literal: true

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
      # prompt_tokens already contains cached_tokens; subtract so the canonical
      # input field means uncached input on every provider.
      uncached = prompt.nil? ? nil : prompt - cached.to_i

      build(input: uncached, output: fetch(raw, :completion_tokens), cache_read: cached, cache_write: nil)
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

    private_class_method :anthropic?, :from_anthropic, :from_openai, :build
  end
end

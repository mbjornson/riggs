# frozen_string_literal: true

require_relative "test_helper"

class TestUsage < Minitest::Test
  def test_normalizes_anthropic_shape
    raw = { "input_tokens" => 100, "output_tokens" => 50,
            "cache_read_input_tokens" => 20, "cache_creation_input_tokens" => 10 }

    u = Riggs::Usage.normalize(raw)

    assert u[:measured]
    assert_equal 100, u[:input_tokens]
    assert_equal 50,  u[:output_tokens]
    assert_equal 20,  u[:cache_read_tokens]
    assert_equal 10,  u[:cache_write_tokens]
    # Anthropic cache fields are additive to input_tokens.
    assert_equal 180, u[:total_tokens]
  end

  def test_normalizes_openai_shape_without_double_counting_cache
    # prompt_tokens INCLUDES cached_tokens, unlike Anthropic.
    raw = { "prompt_tokens" => 100, "completion_tokens" => 50,
            "prompt_tokens_details" => { "cached_tokens" => 20 } }

    u = Riggs::Usage.normalize(raw)

    assert_equal 80, u[:input_tokens], "cached tokens must be subtracted from prompt_tokens"
    assert_equal 20, u[:cache_read_tokens]
    assert_equal 150, u[:total_tokens], "total must equal prompt + completion, not 170"
  end

  def test_accepts_symbol_keys_from_the_mock_provider
    u = Riggs::Usage.normalize({ prompt_tokens: 12, completion_tokens: 34 })

    assert u[:measured]
    assert_equal 12, u[:input_tokens]
    assert_equal 46, u[:total_tokens]
  end

  def test_empty_hash_is_unmeasured_with_nil_values
    u = Riggs::Usage.normalize({})

    refute u[:measured]
    assert_nil u[:input_tokens]
    assert_nil u[:total_tokens]
  end

  def test_nil_is_unmeasured
    refute Riggs::Usage.normalize(nil)[:measured]
  end

  # cursor_cloud returns a NON-EMPTY hash carrying no token data. This is the
  # case that distinguishes "has token keys" from "hash is not empty".
  def test_cursor_cloud_duration_only_hash_is_unmeasured
    u = Riggs::Usage.normalize({ duration_ms: 4200 })

    refute u[:measured], "a non-empty hash without token keys must be unmeasured"
    assert_nil u[:input_tokens]
  end

  def test_partial_usage_is_measured
    u = Riggs::Usage.normalize({ "output_tokens" => 7 })

    assert u[:measured]
    assert_nil u[:input_tokens]
    assert_equal 7, u[:total_tokens]
  end

  def test_estimate_without_an_anchor_uses_the_character_heuristic
    messages = [{ role: "user", content: "a" * 400 }]

    assert_equal 100, Riggs::Usage.estimate(messages)
  end

  def test_estimate_with_an_anchor_only_estimates_the_delta
    messages = [{ role: "user", content: "a" * 4_000 }, { role: "assistant", content: "b" * 400 }]

    # The anchor says the first message really measured 50 tokens, not the 1000
    # the heuristic would guess. Only the second message is estimated.
    assert_equal 150, Riggs::Usage.estimate(messages, anchor: 50, anchored_count: 1)
  end

  def test_estimate_counts_tool_call_payloads
    messages = [{ role: "assistant", content: "", tool_calls: [{ name: "x", arguments: { "k" => "v" * 100 } }] }]

    assert_operator Riggs::Usage.estimate(messages), :>, 20,
                    "serialized tool_calls consume context and must be counted"
  end

  def test_estimate_of_an_empty_array_is_zero
    assert_equal 0, Riggs::Usage.estimate([])
  end

  def test_anchor_larger_than_the_message_list_does_not_go_negative
    assert_operator Riggs::Usage.estimate([{ role: "user", content: "hi" }], anchor: 500, anchored_count: 5),
                    :>=, 0
  end

  # input_tokens means UNCACHED input here, which is right for pricing and
  # wrong for sizing: a 100k prompt served 95k from cache normalizes to
  # input_tokens: 5_000. Anchoring on that sizes the request at a twentieth of
  # what was actually sent.
  def test_prompt_tokens_covers_the_whole_prompt_including_cache_reads
    u = Riggs::Usage.normalize("prompt_tokens" => 100_000, "completion_tokens" => 500,
                               "prompt_tokens_details" => { "cached_tokens" => 95_000 })

    assert_equal 5_000, u[:input_tokens], "the pricing field stays uncached-only"
    assert_equal 100_000, Riggs::Usage.prompt_tokens(u),
                 "the sizing figure must cover every prompt-side token the vendor reported"
  end

  def test_prompt_tokens_sums_anthropics_additive_cache_fields
    u = Riggs::Usage.normalize("input_tokens" => 100, "output_tokens" => 50,
                               "cache_read_input_tokens" => 20, "cache_creation_input_tokens" => 10)

    assert_equal 130, Riggs::Usage.prompt_tokens(u), "output tokens are not part of the prompt"
  end

  # nil means "no anchor, estimate the whole array". 0 would mean "the prompt
  # was empty", which is a different and wrong claim.
  def test_prompt_tokens_is_nil_when_no_prompt_field_was_reported
    u = Riggs::Usage.normalize("output_tokens" => 7)

    assert u[:measured]
    assert_nil Riggs::Usage.prompt_tokens(u)
  end

  def test_prompt_tokens_of_an_unmeasured_usage_is_nil
    assert_nil Riggs::Usage.prompt_tokens(Riggs::Usage.normalize(nil))
    assert_nil Riggs::Usage.prompt_tokens(nil)
  end

  # cached_tokens is documented as a subset of prompt_tokens, so the OpenAI path
  # subtracts. A compatible endpoint that violates that contract used to produce
  # a negative token count, which storage summed and pricing turned into a
  # credit. An impossible reading is not a measurement: report nil.
  def test_cached_tokens_exceeding_prompt_tokens_yields_nil_input
    u = Riggs::Usage.normalize({ "prompt_tokens" => 100, "completion_tokens" => 1,
                                 "prompt_tokens_details" => { "cached_tokens" => 200 } })

    assert_nil u[:input_tokens]
  end

  def test_negative_cached_tokens_yields_nil_input
    u = Riggs::Usage.normalize({ "prompt_tokens" => 100, "completion_tokens" => 1,
                                 "prompt_tokens_details" => { "cached_tokens" => -5 } })

    assert_nil u[:input_tokens]
  end

  def test_cached_tokens_equal_to_prompt_tokens_is_a_valid_full_cache_hit
    u = Riggs::Usage.normalize({ "prompt_tokens" => 100, "completion_tokens" => 1,
                                 "prompt_tokens_details" => { "cached_tokens" => 100 } })

    assert_equal 0, u[:input_tokens]
  end

  def test_no_token_field_is_ever_negative
    u = Riggs::Usage.normalize({ "prompt_tokens" => 10, "completion_tokens" => 1,
                                 "prompt_tokens_details" => { "cached_tokens" => 999 } })
    values = u.values_at(:input_tokens, :output_tokens, :cache_read_tokens,
                         :cache_write_tokens, :total_tokens).compact

    assert_empty values.select(&:negative?)
  end

  # Nulling the derived input field is not enough: the negative count the vendor
  # actually sent was still stored under cache_read_tokens, where storage summed
  # it and pricing turned it into a negative dollar amount.
  def test_a_negative_reported_field_is_dropped_not_stored
    u = Riggs::Usage.normalize({ "prompt_tokens" => 100,
                                 "prompt_tokens_details" => { "cached_tokens" => -5 } })

    assert_nil u[:cache_read_tokens]
    refute u[:total_tokens].to_i.negative?
  end

  def test_a_negative_field_never_reaches_a_cost
    u = Riggs::Usage.normalize({ "prompt_tokens" => 100,
                                 "prompt_tokens_details" => { "cached_tokens" => -5 } })
    cost = Riggs::ModelInfo.cost(model: "gpt-4o-mini", usage: u)

    refute cost.to_f.negative?, "a malformed payload must never produce a credit"
  end

  # An OpenAI-compatible endpoint that serializes its counts as strings used to
  # crash normalization outright (Integer vs String comparison), taking the run
  # down over a bookkeeping field.
  def test_string_shaped_counts_normalize_instead_of_raising
    u = Riggs::Usage.normalize({ "prompt_tokens" => "100", "completion_tokens" => "7",
                                 "prompt_tokens_details" => { "cached_tokens" => "40" } })

    assert_equal 60, u[:input_tokens]
    assert_equal 7, u[:output_tokens]
    assert_equal 40, u[:cache_read_tokens]
  end

  def test_a_non_numeric_count_is_unmeasured_rather_than_fatal
    u = Riggs::Usage.normalize({ "prompt_tokens" => "lots", "completion_tokens" => 7 })

    assert_nil u[:input_tokens]
    assert_equal 7, u[:output_tokens]
  end
end

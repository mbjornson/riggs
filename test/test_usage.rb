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
end

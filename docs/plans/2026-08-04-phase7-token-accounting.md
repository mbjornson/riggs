# Phase 7: Token Accounting and Compaction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop discarding provider `usage`, record tokens and cost per call, and use that measurement to compact message history against a token budget instead of a step count.

**Architecture:** Two new pure modules (`Riggs::Usage`, `Riggs::ModelInfo`) normalize vendor usage and price it. `Providers::Router` merges the result into what it already returns. `ToolLoop` and `GraphEngine` persist rows to a new `riggs_provider_calls` table through a single recording method owned by `GraphEngine`. A `Workflow::Compactor` then consumes those measurements at both message-growth sites.

**Tech Stack:** Ruby 4.0, minitest, RuboCop, SQLite3, Rack.

**Spec:** `docs/specs/phase7-token-accounting-and-compaction.md`

## Global Constraints

- Ruby `>= 4.0.0`. No new gem dependencies — everything here uses stdlib plus what `riggs.gemspec` already declares.
- Every new `lib/` file starts with `# frozen_string_literal: true`.
- RuboCop must pass with zero offenses. `Style/OneClassPerFile` is enforced — one class or module per file, and one test class per test file.
- The pre-commit hook runs `bundle exec rubocop` then `bundle exec rake test` on every commit. Both must pass; do not use `--no-verify`.
- Unmeasured token values are `nil`, never `0`. Unpriced cost is `nil`, never `0`. This rule holds in the normalizer, the schema, the aggregates, and every display surface.
- New `lib/riggs/*.rb` files must be added to the `require_relative` list in `lib/riggs.rb`.
- Schema changes go in **two** places: `db/init_riggs_schema.sql` and the embedded fallback in `Storage#schema_sql` (`lib/riggs/storage.rb:225-282`).
- Tests must not assert specific shipped prices. Prices change; a test pinning `15.0` breaks on every price update. Assert structure, lookup behavior, and override precedence.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `lib/riggs/usage.rb` | Normalize vendor usage hashes; estimate token counts for un-sent messages |
| `lib/riggs/model_info.rb` | Per-model prices and context windows; cost arithmetic |
| `lib/riggs/workflow/compactor.rb` | Ceiling calculation and history compaction, shared by both growth sites |
| `test/test_usage.rb` | Normalization and estimation |
| `test/test_model_info.rb` | Lookup, override precedence, cost arithmetic |
| `test/test_storage_usage.rb` | Recording and aggregation |
| `test/test_compactor.rb` | Ceiling, boundary selection, tool-call grouping |

**Modified:**

| File | Change |
|---|---|
| `db/init_riggs_schema.sql` | `riggs_provider_calls` table + index |
| `lib/riggs/storage.rb` | Embedded fallback schema; `record_provider_call`, `session_usage`, `step_usage` |
| `lib/riggs/providers/base.rb` | Document `model:` in the result contract |
| `lib/riggs/providers/anthropic.rb`, `openai_compatible.rb`, `mock.rb`, `cli.rb`, `cursor_cloud.rb` | Return `model:` |
| `lib/riggs/providers/router.rb` | Normalize usage, compute cost, merge both into the result |
| `lib/riggs/workflow/tool_loop.rb` | `record_call:` injection; pre-flight compaction |
| `lib/riggs/workflow/graph_engine.rb` | `record_provider_call`; token-budgeted `build_messages`; delete `CONTEXT_LIMITS` |
| `lib/riggs/workflow/loader.rb` | `context_window` as a token budget; `reserve_tokens`, `keep_recent_tokens` |
| `lib/riggs/cli/commands.rb` | Usage block in `workflow:inspect`; usage line in `providers:ping` |
| `lib/riggs/web/app.rb` | `GET /api/sessions/:id/usage` |
| `lib/riggs/web/views/session_show.erb` | Usage table |
| `lib/riggs.rb` | Require the new modules |
| `docs/gaps.md`, `CHANGELOG.md`, `README.md` | Mark shipped; document config keys |

---

# Phase A — Token accounting (spec R2.1–R2.7)

## Task 1: `Riggs::Usage` normalization

**Files:**
- Create: `lib/riggs/usage.rb`
- Create: `test/test_usage.rb`
- Modify: `lib/riggs.rb` (add `require_relative "riggs/usage"` after the `storage` line)

**Interfaces:**
- Consumes: nothing.
- Produces: `Riggs::Usage.normalize(raw) -> Hash` with keys `:input_tokens`, `:output_tokens`, `:cache_read_tokens`, `:cache_write_tokens`, `:total_tokens`, `:measured`. Token values are `Integer` or `nil`. `:measured` is `true`/`false`. Consumed by Tasks 4, 5, and 10.

**Critical detail — the two cache conventions differ:**

Anthropic returns `cache_read_input_tokens` **in addition to** `input_tokens`. OpenAI returns `prompt_tokens_details.cached_tokens` **as a subset of** `prompt_tokens`. Summing all four fields blindly double-counts cached tokens on OpenAI. The canonical shape defines `input_tokens` as *uncached input*, so the OpenAI path subtracts. Convention is detected by which key names are present.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/test_usage.rb
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
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `bundle exec ruby -Itest test/test_usage.rb`
Expected: FAIL — `NameError: uninitialized constant Riggs::Usage`

- [ ] **Step 3: Implement**

```ruby
# lib/riggs/usage.rb
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
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `bundle exec ruby -Itest test/test_usage.rb`
Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 5: Mutation-check the cursor_cloud test**

The `measured` rule is the one place a vacuous test would go unnoticed. Temporarily change `build` so it returns measured on any non-empty hash:

```ruby
return EMPTY.dup if parts.all?(&:nil?)   # comment this line out
```

Run the tests again. `test_cursor_cloud_duration_only_hash_is_unmeasured` and `test_empty_hash_is_unmeasured_with_nil_values` must both fail. If they pass, the tests are not testing what they claim. Restore the line.

- [ ] **Step 6: Wire up and commit**

Add to `lib/riggs.rb` after `require_relative "riggs/storage"`:

```ruby
require_relative "riggs/usage"
```

```bash
bundle exec rubocop lib/riggs/usage.rb test/test_usage.rb
git add lib/riggs/usage.rb test/test_usage.rb lib/riggs.rb
git commit -m "Add Riggs::Usage vendor usage normalization"
```

---

## Task 2: `Riggs::ModelInfo` prices and context windows

**Files:**
- Create: `lib/riggs/model_info.rb`
- Create: `test/test_model_info.rb`
- Modify: `lib/riggs.rb`

**Interfaces:**
- Consumes: `Riggs::Usage` normalized shape from Task 1.
- Produces:
  - `Riggs::ModelInfo::AS_OF -> String` (ISO date)
  - `Riggs::ModelInfo.lookup(model, overrides: {}) -> Hash | nil` with keys `:input`, `:output`, `:cache_read`, `:cache_write`, `:context_window`
  - `Riggs::ModelInfo.cost(model:, usage:, overrides: {}) -> Float | nil`
  - `Riggs::ModelInfo.context_window(model, overrides: {}) -> Integer | nil`
  - Consumed by Tasks 4 and 10.

- [ ] **Step 1: Source the price data — do not recall it from memory**

Open the vendor pricing and model documentation and transcribe current values. A misremembered price produces a confidently wrong dollar figure, which is worse than the `nil` this design already handles gracefully.

Required coverage:
- Every Anthropic Claude model available at the time of implementation.
- The OpenAI models named in `DEFAULT_MODEL` in `lib/riggs/providers/openai_compatible.rb` and `lib/riggs/providers/anthropic.rb`.
- Any model referenced in `config/riggs/workflows/`.

Record prices as **USD per 1,000,000 tokens** and set `AS_OF` to the date you retrieved them.

- [ ] **Step 2: Write the failing tests**

Note these tests define a fixture table and never assert against shipped prices — shipped values change, and a test pinning them would fail on every price update rather than on a real regression.

```ruby
# test/test_model_info.rb
# frozen_string_literal: true

require_relative "test_helper"

class TestModelInfo < Minitest::Test
  FIXTURE = {
    "test-model" => { input: 10.0, output: 30.0, cache_read: 1.0, cache_write: 12.0,
                      context_window: 200_000 }
  }.freeze

  def test_as_of_is_an_iso_date
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, Riggs::ModelInfo::AS_OF)
  end

  def test_shipped_table_entries_all_have_the_required_keys
    Riggs::ModelInfo::TABLE.each do |model, info|
      %i[input output context_window].each do |key|
        refute_nil info[key], "#{model} is missing #{key}"
      end
    end
  end

  def test_lookup_returns_nil_for_unknown_model
    assert_nil Riggs::ModelInfo.lookup("no-such-model")
  end

  def test_lookup_returns_nil_for_nil_model
    assert_nil Riggs::ModelInfo.lookup(nil)
  end

  def test_overrides_beat_the_shipped_table
    shipped = Riggs::ModelInfo::TABLE.keys.first
    overrides = { shipped => { input: 999.0 } }

    assert_equal 999.0, Riggs::ModelInfo.lookup(shipped, overrides: overrides)[:input]
  end

  def test_overrides_merge_rather_than_replace
    shipped = Riggs::ModelInfo::TABLE.keys.first
    expected_window = Riggs::ModelInfo::TABLE[shipped][:context_window]
    overrides = { shipped => { input: 999.0 } }

    assert_equal expected_window,
                 Riggs::ModelInfo.lookup(shipped, overrides: overrides)[:context_window]
  end

  def test_overrides_can_introduce_an_unknown_model
    info = Riggs::ModelInfo.lookup("self-hosted-llama", overrides: { "self-hosted-llama" => { input: 0.0, output: 0.0 } })

    assert_equal 0.0, info[:input]
  end

  def test_cost_sums_all_four_rates_per_million
    usage = { input_tokens: 1_000_000, output_tokens: 1_000_000,
              cache_read_tokens: 1_000_000, cache_write_tokens: 1_000_000, measured: true }

    cost = Riggs::ModelInfo.cost(model: "test-model", usage: usage, overrides: FIXTURE)

    assert_in_delta 53.0, cost, 0.0001 # 10 + 30 + 1 + 12
  end

  def test_cost_prorates_partial_millions
    usage = { input_tokens: 500_000, output_tokens: nil, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_in_delta 5.0, Riggs::ModelInfo.cost(model: "test-model", usage: usage, overrides: FIXTURE), 0.0001
  end

  def test_cost_is_nil_when_usage_is_unmeasured
    assert_nil Riggs::ModelInfo.cost(model: "test-model", usage: Riggs::Usage::EMPTY, overrides: FIXTURE)
  end

  def test_cost_is_nil_for_an_unpriced_model
    usage = { input_tokens: 100, output_tokens: 100, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_nil Riggs::ModelInfo.cost(model: "unpriced", usage: usage, overrides: FIXTURE)
  end

  def test_cost_is_nil_when_model_is_nil
    usage = { input_tokens: 100, output_tokens: 100, cache_read_tokens: nil,
              cache_write_tokens: nil, measured: true }

    assert_nil Riggs::ModelInfo.cost(model: nil, usage: usage, overrides: FIXTURE)
  end

  def test_context_window_reads_through_overrides
    assert_equal 200_000, Riggs::ModelInfo.context_window("test-model", overrides: FIXTURE)
    assert_nil Riggs::ModelInfo.context_window("unknown")
  end
end
```

- [ ] **Step 3: Run the tests and watch them fail**

Run: `bundle exec ruby -Itest test/test_model_info.rb`
Expected: FAIL — `NameError: uninitialized constant Riggs::ModelInfo`

- [ ] **Step 4: Implement**

Fill `TABLE` with the values sourced in Step 1.

```ruby
# lib/riggs/model_info.rb
# frozen_string_literal: true

module Riggs
  # Per-model prices and context windows.
  #
  # Pricing and context window are one table rather than two, because they are
  # keyed identically and two parallel tables could disagree about which models
  # exist. Prices are USD per 1,000,000 tokens.
  #
  # AS_OF makes staleness visible. `.agent_hubrc` overrides win, so anyone on
  # negotiated rates or a self-hosted model is never bound to these numbers.
  module ModelInfo
    AS_OF = "REPLACE-WITH-RETRIEVAL-DATE"

    TABLE = {
      # "model-id" => { input:, output:, cache_read:, cache_write:, context_window: },
      # Populated in Step 1 from vendor documentation.
    }.freeze

    PER_MILLION = 1_000_000.0

    RATE_FIELDS = {
      input_tokens: :input,
      output_tokens: :output,
      cache_read_tokens: :cache_read,
      cache_write_tokens: :cache_write
    }.freeze

    def self.lookup(model, overrides: {})
      return nil if model.nil? || model.to_s.empty?

      key = model.to_s
      shipped = TABLE[key]
      override = normalize_overrides(overrides)[key]
      return nil if shipped.nil? && override.nil?

      (shipped || {}).merge(override || {})
    end

    def self.context_window(model, overrides: {})
      lookup(model, overrides: overrides)&.fetch(:context_window, nil)
    end

    # Returns nil — never 0 — when the call was unmeasured or the model has no
    # price entry. A zero would be indistinguishable from a genuinely free call.
    def self.cost(model:, usage:, overrides: {})
      return nil unless usage.is_a?(Hash) && usage[:measured]

      rates = lookup(model, overrides: overrides)
      return nil if rates.nil?

      total = RATE_FIELDS.sum do |usage_key, rate_key|
        tokens = usage[usage_key]
        rate = rates[rate_key]
        tokens.nil? || rate.nil? ? 0.0 : (tokens / PER_MILLION) * rate
      end
      total.to_f
    end

    def self.normalize_overrides(overrides)
      return {} unless overrides.is_a?(Hash)

      overrides.each_with_object({}) do |(model, rates), acc|
        next unless rates.is_a?(Hash)

        acc[model.to_s] = rates.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end
    end

    private_class_method :normalize_overrides
  end
end
```

- [ ] **Step 5: Run the tests and watch them pass**

Run: `bundle exec ruby -Itest test/test_model_info.rb`
Expected: PASS, 14 runs, 0 failures.

`test_shipped_table_entries_all_have_the_required_keys` passes vacuously on an empty `TABLE` — it only earns its keep once Step 1's data is in. Confirm `TABLE` is populated before moving on.

- [ ] **Step 6: Wire up and commit**

```ruby
# lib/riggs.rb, after the usage require
require_relative "riggs/model_info"
```

```bash
bundle exec rubocop lib/riggs/model_info.rb test/test_model_info.rb
git add lib/riggs/model_info.rb test/test_model_info.rb lib/riggs.rb
git commit -m "Add Riggs::ModelInfo per-model prices and context windows"
```

---

## Task 3: Providers report their resolved model

**Files:**
- Modify: `lib/riggs/providers/base.rb:20` (contract comment)
- Modify: `lib/riggs/providers/anthropic.rb`, `openai_compatible.rb`, `mock.rb`, `cli.rb`, `cursor_cloud.rb`
- Modify: `test/test_providers.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: every provider result hash gains `model:` (`String` or `nil`). Consumed by Task 4.

Prefer `data["model"]` from the response body over the configured value — both Anthropic and OpenAI echo the *resolved* model, collapsing aliases such as `-latest` into a concrete version, which is what pricing must key on.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_providers.rb` inside the existing test class:

```ruby
  def test_mock_provider_reports_its_model
    provider = Riggs::Providers::Mock.new(name: "mock", options: { model: "mock-1" })

    result = provider.complete(messages: [{ role: "user", content: "hi" }])

    assert_equal "mock-1", result[:model]
  end

  def test_mock_provider_model_is_nil_when_unconfigured
    provider = Riggs::Providers::Mock.new(name: "mock", options: {})

    assert_nil provider.complete(messages: [{ role: "user", content: "hi" }])[:model]
  end

  def test_anthropic_prefers_the_model_echoed_by_the_response
    parsed = Riggs::Providers::Anthropic
             .new(name: "anthropic", options: { model: "claude-alias-latest" })
             .send(:parse_anthropic_content,
                   { "content" => [{ "type" => "text", "text" => "ok" }],
                     "model" => "claude-resolved-20260101", "usage" => {} })

    assert_equal "claude-resolved-20260101", parsed[:model],
                 "the echoed model resolves aliases and must win over the configured value"
  end

  def test_anthropic_falls_back_to_the_configured_model
    parsed = Riggs::Providers::Anthropic
             .new(name: "anthropic", options: { model: "claude-configured" })
             .send(:parse_anthropic_content,
                   { "content" => [{ "type" => "text", "text" => "ok" }], "usage" => {} })

    assert_equal "claude-configured", parsed[:model]
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_providers.rb`
Expected: FAIL — `Expected: "mock-1" Actual: nil` and equivalents.

- [ ] **Step 3: Implement**

In `lib/riggs/providers/base.rb`, update the contract comment on line 20:

```ruby
      # Returns { provider:, model:, content:, tool_calls: [], usage:, raw: }
```

In `lib/riggs/providers/anthropic.rb`, add `model:` to the hash returned by `parse_anthropic_content`:

```ruby
        {
          provider: name,
          model: data["model"] || options[:model],
          content: text,
          tool_calls: tool_calls,
          usage: data["usage"] || {},
          raw: data
        }
```

In `lib/riggs/providers/openai_compatible.rb`, in the `when 200` branch:

```ruby
          {
            provider: name,
            model: data["model"] || options[:model],
            content: content,
            tool_calls: tool_calls,
            usage: data["usage"] || {},
            raw: data
          }
```

In `lib/riggs/providers/mock.rb`, add `model: options[:model]` to all three returned hashes (near lines 19, 44, 53) and the one at line 70.

In `lib/riggs/providers/cli.rb` (line 29 area) and `lib/riggs/providers/cursor_cloud.rb` (line 38 area), add `model: options[:model]`. These providers have no response body to read a model from.

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rake test`
Expected: PASS. All 129 existing tests plus the new ones. Adding a key to a hash breaks nothing that reads other keys.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop
git add lib/riggs/providers test/test_providers.rb
git commit -m "Providers report their resolved model in the result hash"
```

---

## Task 4: Router normalizes usage and computes cost

**Files:**
- Modify: `lib/riggs/providers/router.rb:38-64`
- Modify: `test/test_providers.rb`

**Interfaces:**
- Consumes: `Riggs::Usage.normalize` (Task 1), `Riggs::ModelInfo.cost` (Task 2), provider `model:` (Task 3).
- Produces: `Router#call` result gains `usage:` (normalized shape, replacing the raw vendor hash) and `cost_usd:` (`Float` or `nil`). `raw:` still holds the untouched vendor response. Consumed by Task 6.

Router is the right home for pricing because it is the only component that resolves provider configuration — `provider_config(name)` merges hub ← workflow, and the per-model override lives there. Downstream that configuration is gone.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_providers.rb`:

```ruby
  def test_router_normalizes_usage_on_the_result
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })

    result = router.call(chain: ["mock"], messages: [{ role: "user", content: "hello" }])

    assert result[:usage][:measured]
    assert_kind_of Integer, result[:usage][:total_tokens]
  end

  def test_router_prices_a_call_using_hubrc_overrides
    router = Riggs::Providers::Router.new(
      hub_providers: {
        mock: { type: "mock", model: "priced-model",
                pricing: { "priced-model" => { input: 1000.0, output: 1000.0 } } }
      }
    )

    result = router.call(chain: ["mock"], messages: [{ role: "user", content: "hello" }])

    refute_nil result[:cost_usd]
    assert result[:cost_usd].positive?
  end

  def test_router_cost_is_nil_for_an_unpriced_model
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock", model: "unpriced-xyz" } })

    result = router.call(chain: ["mock"], messages: [{ role: "user", content: "hello" }])

    assert result[:usage][:measured], "tokens still record even when the model has no price"
    assert_nil result[:cost_usd]
  end

  def test_router_replaces_vendor_usage_but_preserves_it_under_raw
    router = Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } })

    result = router.call(chain: ["mock"], messages: [{ role: "user", content: "hello" }])

    # The normalized shape uses canonical names...
    assert_includes result[:usage].keys, :input_tokens
    refute_includes result[:usage].keys, :prompt_tokens
    # ...while raw keeps the vendor's own.
    assert_includes result[:raw][:usage].keys, :prompt_tokens
    assert_equal 5, result[:raw][:usage][:prompt_tokens], "mock counts the user text length"
  end

  # R2.7: usage belongs to the provider that answered, not the first one tried.
  def test_router_attributes_usage_to_the_provider_that_answered
    failing = Class.new(Riggs::Providers::Base) do
      def complete(**)
        raise Riggs::Providers::RateLimitError, "429"
      end
    end
    router = Riggs::Providers::Router.new(
      hub_providers: { flaky: { type: "flaky" }, mock: { type: "mock" } },
      registry: { "flaky" => failing, "mock" => Riggs::Providers::Mock }
    )

    result = router.call(chain: %w[flaky mock], messages: [{ role: "user", content: "hello" }])

    assert_equal "mock", result[:provider]
    assert_equal 2, result[:relay_attempt]
    assert result[:usage][:measured], "the answering provider's usage is what gets recorded"
  end
```

Note: `raw:` is not currently set by `Mock`. Task 4 Step 3 adds it so the normalized-vs-raw distinction is testable on the one provider tests can run offline.

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_providers.rb`
Expected: FAIL — `NoMethodError: undefined method '[]' for nil` on `result[:usage][:measured]`, because `usage` is still the raw symbol-keyed mock hash without a `:measured` key.

- [ ] **Step 3: Implement**

In `lib/riggs/providers/mock.rb`, add `raw:` to the final result hash (line 70 area) so the raw payload survives normalization:

```ruby
        usage = { prompt_tokens: user_text.length, completion_tokens: body.length }
        {
          provider: name,
          model: options[:model],
          content: tool_calls.empty? ? body : "",
          tool_calls: tool_calls,
          usage: usage,
          raw: { usage: usage }
        }
```

In `lib/riggs/providers/router.rb`, replace the success branch inside `call` (currently lines 44-52):

```ruby
          provider = build(name)
          result = provider.complete(messages: messages, system: system, timeout: timeout, tools: tools)
          result[:tool_calls] ||= []
          metered = meter(result, name)
          @audit&.call(
            session_id: session_id,
            event_type: "provider_success",
            payload: { provider: name, attempt: idx + 1,
                       tokens: metered[:usage][:total_tokens], cost_usd: metered[:cost_usd] }
          )
          return metered.merge(relay_attempt: idx + 1)
```

Add to the `private` section:

```ruby
      # Normalizes vendor usage and prices it. Only Router resolves provider
      # config, so the per-model pricing override is only reachable here.
      def meter(result, name)
        opts = provider_config(name)
        usage = Usage.normalize(result[:usage])
        overrides = opts[:pricing] || {}
        result.merge(
          usage: usage,
          cost_usd: ModelInfo.cost(model: result[:model], usage: usage, overrides: overrides)
        )
      end
```

Add the requires at the top of `router.rb`, after the existing `require_relative` lines:

```ruby
require_relative "../usage"
require_relative "../model_info"
```

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rake test`
Expected: PASS.

If `test_router_preserves_the_raw_vendor_usage` fails, check that `Mock` sets `raw:` — the normalized `usage` intentionally replaces the vendor shape, so `raw` is the only remaining route to the original.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop
git add lib/riggs/providers/router.rb lib/riggs/providers/mock.rb test/test_providers.rb
git commit -m "Router normalizes provider usage and computes cost"
```

---

## Task 5: Schema and Storage recording plus aggregation

**Files:**
- Modify: `db/init_riggs_schema.sql`
- Modify: `lib/riggs/storage.rb` (embedded fallback schema at `:225-282`, plus three new methods)
- Create: `test/test_storage_usage.rb`
- Modify: `test/test_storage_migration.rb`

**Interfaces:**
- Consumes: the normalized usage shape from Task 1.
- Produces:
  - `Storage#record_provider_call(session_id:, step_key:, provider:, model:, relay_attempt:, usage:, cost_usd:) -> Integer` (row id)
  - `Storage#session_usage(session_id) -> Hash` with `:input_tokens`, `:output_tokens`, `:cache_read_tokens`, `:cache_write_tokens`, `:total_tokens`, `:cost_usd`, `:calls`, `:measured_calls`, `:priced_calls`
  - `Storage#step_usage(session_id) -> Array<Hash>` — same keys plus `:step_key`, ordered by first call
  - Consumed by Tasks 6 and 7.

**The schema lives in two places.** `db/init_riggs_schema.sql` is the source of truth; `Storage#schema_sql` carries an embedded fallback for when the gem layout puts the SQL file out of reach. Phase 6 remembered to add `riggs_messages` to both. Miss the second and the table exists in development and vanishes in a packaged gem.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/test_storage_usage.rb
# frozen_string_literal: true

require_relative "test_helper"

class TestStorageUsage < Minitest::Test
  MEASURED = { input_tokens: 100, output_tokens: 50, cache_read_tokens: 20,
               cache_write_tokens: 10, total_tokens: 180, measured: true }.freeze

  def setup
    @dir = Dir.mktmpdir("riggs-storage-usage")
    @storage = Riggs::Storage.new(db_path: File.join(@dir, "db", "riggs.sqlite3"))
    @session_id = @storage.create_session(
      workflow_name: "example_triage", user_id: "eng_bob", memory_namespace: "ns"
    )
  end

  def teardown
    @storage.close
    FileUtils.remove_entry(@dir)
  end

  def record(step_key: "triage", usage: MEASURED, cost_usd: 0.25, provider: "anthropic",
             model: "test-model", relay_attempt: 1)
    @storage.record_provider_call(
      session_id: @session_id, step_key: step_key, provider: provider, model: model,
      relay_attempt: relay_attempt, usage: usage, cost_usd: cost_usd
    )
  end

  def test_records_a_measured_call
    record

    row = @storage.db.get_first_row("SELECT * FROM riggs_provider_calls WHERE session_id = ?", [@session_id])

    assert_equal 100, row["input_tokens"]
    assert_equal 1, row["measured"]
    assert_in_delta 0.25, row["cost_usd"], 0.0001
    assert_equal "anthropic", row["provider"]
  end

  # NULL, not 0. A zero is indistinguishable from a genuinely empty call.
  def test_unmeasured_call_stores_nulls_not_zeros
    record(usage: Riggs::Usage::EMPTY, cost_usd: nil)

    row = @storage.db.get_first_row("SELECT * FROM riggs_provider_calls WHERE session_id = ?", [@session_id])

    assert_nil row["input_tokens"]
    assert_nil row["cost_usd"]
    assert_equal 0, row["measured"]
  end

  def test_session_usage_sums_measured_calls_only
    record
    record
    record(usage: Riggs::Usage::EMPTY, cost_usd: nil)

    totals = @storage.session_usage(@session_id)

    assert_equal 200, totals[:input_tokens]
    assert_equal 360, totals[:total_tokens]
    assert_equal 3, totals[:calls]
    assert_equal 2, totals[:measured_calls]
  end

  def test_session_usage_counts_measured_and_priced_independently
    record                                  # measured + priced
    record(cost_usd: nil)                   # measured, unpriced
    record(usage: Riggs::Usage::EMPTY, cost_usd: nil) # neither

    totals = @storage.session_usage(@session_id)

    assert_equal 3, totals[:calls]
    assert_equal 2, totals[:measured_calls]
    assert_equal 1, totals[:priced_calls]
  end

  def test_session_usage_on_an_empty_session_reports_zero_calls_and_nil_totals
    totals = @storage.session_usage(@session_id)

    assert_equal 0, totals[:calls]
    assert_nil totals[:total_tokens]
    assert_nil totals[:cost_usd]
  end

  def test_step_usage_groups_by_step_key
    record(step_key: "triage")
    record(step_key: "triage")
    record(step_key: "draft")

    rows = @storage.step_usage(@session_id)

    assert_equal 2, rows.length
    triage = rows.find { |r| r[:step_key] == "triage" }

    assert_equal 2, triage[:calls]
    assert_equal 200, triage[:input_tokens]
  end

  def test_relay_attempt_records_the_answering_attempt
    record(provider: "openai", relay_attempt: 2)

    row = @storage.db.get_first_row("SELECT * FROM riggs_provider_calls WHERE session_id = ?", [@session_id])

    assert_equal 2, row["relay_attempt"]
    assert_equal "openai", row["provider"]
  end
end
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_storage_usage.rb`
Expected: FAIL — `NoMethodError: undefined method 'record_provider_call'`

- [ ] **Step 3: Add the schema in both places**

Append to `db/init_riggs_schema.sql`, after the `riggs_audit` table:

```sql
-- Per provider call metering. Token columns are nullable with no default:
-- NULL means the provider reported no usage (all CLI providers), which is a
-- different fact from a genuine zero. DEFAULT 0 would erase that distinction.
CREATE TABLE IF NOT EXISTS riggs_provider_calls (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id         TEXT NOT NULL REFERENCES riggs_sessions(id),
  step_key           TEXT NOT NULL,
  provider           TEXT NOT NULL,
  model              TEXT,
  relay_attempt      INTEGER NOT NULL DEFAULT 1,
  measured           INTEGER NOT NULL DEFAULT 0,
  input_tokens       INTEGER,
  output_tokens      INTEGER,
  cache_read_tokens  INTEGER,
  cache_write_tokens INTEGER,
  cost_usd           REAL,
  created_at         DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

And with the other index declarations at the bottom:

```sql
CREATE INDEX IF NOT EXISTS idx_riggs_provider_calls_session ON riggs_provider_calls(session_id, step_key);
```

Then add the identical `CREATE TABLE` and `CREATE INDEX` to the embedded fallback heredoc in `Storage#schema_sql`, after the `riggs_audit` block.

- [ ] **Step 4: Implement the storage methods**

Add to `lib/riggs/storage.rb` after `list_audit`:

```ruby
    def record_provider_call(session_id:, step_key:, provider:, model:, relay_attempt:, usage:, cost_usd:)
      u = usage || Usage::EMPTY
      @db.execute(
        "INSERT INTO riggs_provider_calls " \
        "(session_id, step_key, provider, model, relay_attempt, measured, " \
        " input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [utf8(session_id), step_key.to_s, provider.to_s, model&.to_s, relay_attempt.to_i,
         u[:measured] ? 1 : 0, u[:input_tokens], u[:output_tokens],
         u[:cache_read_tokens], u[:cache_write_tokens], cost_usd]
      )
      @db.last_insert_row_id
    end

    def session_usage(session_id)
      row = @db.get_first_row("#{USAGE_SELECT} WHERE session_id = ?", [utf8(session_id)])
      usage_row(row)
    end

    def step_usage(session_id)
      rows = @db.execute(
        "#{USAGE_SELECT}, step_key, MIN(id) AS first_id WHERE session_id = ? GROUP BY step_key ORDER BY first_id ASC",
        [utf8(session_id)]
      )
      rows.map { |r| usage_row(r).merge(step_key: r["step_key"]) }
    end
```

Add the constant near the top of the class, under `attr_reader`:

```ruby
    # SUM ignores NULLs, so unmeasured calls fall out of the token totals and
    # unpriced calls fall out of the cost total without any special casing.
    USAGE_SELECT = <<~SQL
      SELECT COUNT(*) AS calls,
             SUM(measured) AS measured_calls,
             SUM(CASE WHEN cost_usd IS NOT NULL THEN 1 ELSE 0 END) AS priced_calls,
             SUM(input_tokens) AS input_tokens,
             SUM(output_tokens) AS output_tokens,
             SUM(cache_read_tokens) AS cache_read_tokens,
             SUM(cache_write_tokens) AS cache_write_tokens,
             SUM(cost_usd) AS cost_usd
      FROM riggs_provider_calls
    SQL
```

And this private helper, next to `deep_symbolize`:

```ruby
    def usage_row(row)
      return empty_usage_row if row.nil?

      tokens = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens]
                 .to_h { |k| [k, row[k.to_s]] }
      total = tokens.values.compact
      tokens.merge(
        total_tokens: total.empty? ? nil : total.sum,
        cost_usd: row["cost_usd"],
        calls: row["calls"].to_i,
        measured_calls: row["measured_calls"].to_i,
        priced_calls: row["priced_calls"].to_i
      )
    end

    def empty_usage_row
      { input_tokens: nil, output_tokens: nil, cache_read_tokens: nil, cache_write_tokens: nil,
        total_tokens: nil, cost_usd: nil, calls: 0, measured_calls: 0, priced_calls: 0 }
    end
```

Add `require_relative "usage"` at the top of `storage.rb` — `Storage` is documented as loadable on its own, so it must not rely on `lib/riggs.rb` having run.

- [ ] **Step 5: Run and watch them pass**

Run: `bundle exec ruby -Itest test/test_storage_usage.rb`
Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 6: Extend the migration test**

`test/test_storage_migration.rb` builds a pre-Phase-6 database by hand and asserts the migration runs. A brand-new table needs no `ALTER`, but the test must prove `CREATE TABLE IF NOT EXISTS` reaches an existing database. Add:

```ruby
  def test_opening_a_legacy_database_creates_the_provider_calls_table
    Riggs::Storage.new(db_path: @db_path).close

    assert_includes raw_tables, "riggs_provider_calls"
  end
```

And extend the existing drift guard `test_fixture_really_predates_the_migration` with:

```ruby
    refute_includes raw_tables, "riggs_provider_calls"
```

- [ ] **Step 7: Run the full suite and commit**

Run: `bundle exec rake test`
Expected: PASS.

```bash
bundle exec rubocop
git add db/init_riggs_schema.sql lib/riggs/storage.rb test/test_storage_usage.rb test/test_storage_migration.rb
git commit -m "Add riggs_provider_calls table with recording and aggregation"
```

---

## Task 6: ToolLoop records; GraphEngine owns the path

**Files:**
- Modify: `lib/riggs/workflow/tool_loop.rb:10-23`, `:38-49`
- Modify: `lib/riggs/workflow/graph_engine.rb:194-206`, plus a new private method
- Modify: `test/test_tool_loop.rb`

**Interfaces:**
- Consumes: `Router#call` result keys `usage:`, `cost_usd:`, `model:`, `relay_attempt:` (Task 4); `Storage#record_provider_call` (Task 5).
- Produces:
  - `ToolLoop.new(..., record_call: nil)` — a keyword accepting a callable invoked as `record_call.call(step_key:, provider:, model:, relay_attempt:, usage:, cost_usd:)`
  - `GraphEngine#record_provider_call(step_key:, provider:, model:, relay_attempt:, usage:, cost_usd:)` — private, wired into `ToolLoop`, and called directly by Task 12's cross-step compaction.
  - Consumed by Tasks 7, 11, 12.

Follow the existing `persist:` pattern exactly, including nil-safety — `test_tool_loop.rb` constructs a loop with no storage at all and must keep working.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tool_loop.rb`:

```ruby
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
    assert recorded.first[:usage][:measured]
    assert_equal 1, recorded.first[:relay_attempt]
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
```

Add this helper to the same class if one does not already exist — check the file first and reuse the existing step construction if present:

```ruby
  def build_step
    Riggs::Workflow::StepNode.from_hash(
      { "id" => "triage", "agent" => "triager", "input" => "x", "output_var" => "out" }
    )
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_tool_loop.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :record_call`

- [ ] **Step 3: Implement ToolLoop**

Change the constructor signature (line 10-11) and add the ivar:

```ruby
      def initialize(router:, mcp_manager:, skill_registry:, audit:, llm_calls:, max_llm_calls:, timeout_seconds:,
                     started_at:, session_id:, persist: nil, record_call: nil)
```

```ruby
        # Optional: a nil persist keeps the loop usable without any storage.
        @persist = persist
        # Same contract for metering — a loop with no storage records nothing.
        @record_call = record_call
```

After `@llm_calls += 1` (line 46), add:

```ruby
          @record_call&.call(
            step_key: step.id, provider: result[:provider], model: result[:model],
            relay_attempt: result[:relay_attempt] || 1,
            usage: result[:usage], cost_usd: result[:cost_usd]
          )
```

- [ ] **Step 4: Implement the GraphEngine recording path**

Add near `audit_bridge` in `lib/riggs/workflow/graph_engine.rb`:

```ruby
      # The single writer for riggs_provider_calls. ToolLoop receives this as an
      # injected callable; cross-step compaction calls it directly. One writer
      # means the column set cannot drift between the two call sites.
      def record_provider_call(step_key:, provider:, model:, relay_attempt:, usage:, cost_usd:)
        return unless @session_id

        @storage.record_provider_call(
          session_id: @session_id, step_key: step_key, provider: provider, model: model,
          relay_attempt: relay_attempt, usage: usage, cost_usd: cost_usd
        )
      end
```

Wire it into the `ToolLoop.new` call (line 194-206):

```ruby
            audit: method(:audit_bridge),
            persist: method(:persist_bridge),
            record_call: method(:record_provider_call),
```

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rake test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
bundle exec rubocop
git add lib/riggs/workflow/tool_loop.rb lib/riggs/workflow/graph_engine.rb test/test_tool_loop.rb
git commit -m "Record each provider call through a single GraphEngine writer"
```

---

## Task 7: Surfaces — CLI, JSON API, web view

**Files:**
- Modify: `lib/riggs/cli/commands.rb` (`workflow_inspect` at `:406`, `providers_ping` at `:537`)
- Modify: `lib/riggs/web/app.rb` (`dispatch` route table, plus a new handler)
- Modify: `lib/riggs/web/views/session_show.erb`
- Modify: `test/test_web_app.rb`

**Interfaces:**
- Consumes: `Storage#session_usage`, `Storage#step_usage` (Task 5).
- Produces: `GET /api/sessions/:id/usage` returning `{ session: {...}, steps: [...] }`. No later task consumes this.

**Coverage is never omitted.** Every total renders with both counters. A bare number implies complete measurement the data may not have.

- [ ] **Step 1: Write the failing test**

Append to `test/test_web_app.rb`, following the existing request-helper style in that file:

```ruby
  def test_usage_endpoint_reports_totals_with_coverage
    login_as("eng_bob")
    session_id = create_session_with_usage

    get "/api/sessions/#{session_id}/usage"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)

    assert_equal 2, body["session"]["calls"]
    assert_equal 1, body["session"]["measured_calls"]
    assert_equal 1, body["steps"].length
  end

  def test_usage_endpoint_requires_inspect_run
    login_as("view_cara")
    session_id = create_session_with_usage

    get "/api/sessions/#{session_id}/usage"

    assert_equal 200, last_response.status, "viewer holds inspect_run"
  end
```

Add the fixture helper to the same class:

```ruby
  def create_session_with_usage
    storage = Riggs::Storage.new(db_path: "./db/riggs.sqlite3")
    id = storage.create_session(workflow_name: "example_triage", user_id: "eng_bob", memory_namespace: "ns")
    storage.record_provider_call(
      session_id: id, step_key: "triage", provider: "mock", model: "m", relay_attempt: 1,
      usage: { input_tokens: 10, output_tokens: 5, cache_read_tokens: nil,
               cache_write_tokens: nil, total_tokens: 15, measured: true },
      cost_usd: 0.01
    )
    storage.record_provider_call(
      session_id: id, step_key: "triage", provider: "claude_cli", model: nil, relay_attempt: 1,
      usage: Riggs::Usage::EMPTY, cost_usd: nil
    )
    storage.close
    id
  end
```

- [ ] **Step 2: Run and watch it fail**

Run: `bundle exec ruby -Itest test/test_web_app.rb`
Expected: FAIL — 404, because the route does not exist.

- [ ] **Step 3: Add the route**

In `lib/riggs/web/app.rb#dispatch`, add alongside the other `/api/sessions/:id/...` matchers — **before** the bare `/api/sessions/:id` route, matching how the events routes were ordered in Phase 6:

```ruby
        if m == "GET" && (sm = p.match(%r{\A/api/sessions/([^/]+)/usage\z}))
          return api_session_usage(sm[1])
        end
```

Add the handler near `api_session_audit`:

```ruby
      def api_session_usage(id)
        require!(identity, "inspect_run")
        sid = Storage.utf8(id)
        json(200, { session: storage.session_usage(sid), steps: storage.step_usage(sid) })
      end
```

Match the existing permission-check and `json(...)` helper usage in the surrounding methods — read `api_session_audit` and copy its shape rather than inventing one.

- [ ] **Step 4: Add the CLI block**

In `workflow_inspect` (`lib/riggs/cli/commands.rb:406`), after the status line and before the audit loop:

```ruby
      usage = storage.session_usage(session_id)
      puts "Tokens: #{format_usage(usage)}"
      storage.step_usage(session_id).each do |row|
        puts "  #{row[:step_key]}: #{format_usage(row)}"
      end
```

Add to the `no_commands do` block:

```ruby
      # Never prints a total without its coverage — a bare number would imply
      # complete measurement that CLI providers cannot supply.
      def format_usage(u)
        return "no provider calls" if u[:calls].zero?

        tokens = u[:total_tokens] ? "#{u[:total_tokens]} tokens" : "unmeasured"
        cost = u[:cost_usd] ? format("$%.4f over %d of %d priced", u[:cost_usd], u[:priced_calls], u[:calls]) : "unpriced"
        "#{tokens} over #{u[:measured_calls]} of #{u[:calls]} calls · #{cost}"
      end
```

In `providers_ping` (`:537`), after the existing `relay_attempt` line:

```ruby
        puts "   usage=#{result[:usage][:measured] ? result[:usage][:total_tokens].to_s : 'unmeasured'} " \
             "cost=#{result[:cost_usd] ? format('$%.6f', result[:cost_usd]) : 'unpriced'}"
```

- [ ] **Step 5: Add the web view section**

In `lib/riggs/web/views/session_show.erb`, add before the `<h2>Audit</h2>` heading, following the markup of the existing tables in that file:

```erb
<h2>Usage</h2>
<table>
  <tr><th>Step</th><th>Tokens</th><th>Calls measured</th><th>Cost</th><th>Calls priced</th></tr>
  <% steps_usage.each do |row| %>
    <tr>
      <td><%= row[:step_key] %></td>
      <td><%= row[:total_tokens] || "unmeasured" %></td>
      <td><%= row[:measured_calls] %> of <%= row[:calls] %></td>
      <td><%= row[:cost_usd] ? format("$%.4f", row[:cost_usd]) : "unpriced" %></td>
      <td><%= row[:priced_calls] %> of <%= row[:calls] %></td>
    </tr>
  <% end %>
</table>
```

Pass the data in from `show_session` (`app.rb:290`):

```ruby
        html(:session_show, title: "Session", session: session, audit: audit,
             steps_usage: storage.step_usage(id))
```

- [ ] **Step 6: Run the full suite and commit**

Run: `bundle exec rake test`
Expected: PASS.

```bash
bundle exec rubocop
git add lib/riggs/cli/commands.rb lib/riggs/web test/test_web_app.rb
git commit -m "Surface token usage and cost in CLI, JSON API, and web view"
```

**Phase A is complete.** A run now reports tokens and cost per step and per session with explicit coverage. Verify by hand before continuing:

```bash
bundle exec exe/riggs workflow:run example_triage
bundle exec exe/riggs workflow:inspect <session-id>
```

---

# Phase B — Compaction (spec R3.1–R3.6)

## Task 8: `context_window` becomes a token budget

**Files:**
- Modify: `lib/riggs/workflow/loader.rb:26`
- Modify: `lib/riggs/workflow/graph_engine.rb:16` (delete `CONTEXT_LIMITS`)
- Modify: `test/test_loader.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `workflow[:context_window] -> Integer` (was `Symbol`), plus new `workflow[:reserve_tokens] -> Integer` and `workflow[:keep_recent_tokens] -> Integer`. Consumed by Tasks 10, 11, 12.

`loader.rb:26` currently reads `(cfg[:context_window] || :medium).to_s.to_sym`, which turns an integer `60000` into the symbol `:"60000"`. Parsing has to change, not just the lookup.

- [ ] **Step 1: Write the failing tests**

```ruby
  def test_context_window_words_resolve_to_token_budgets
    assert_equal 8_000, load_workflow_with("context_window" => "short")[:context_window]
    assert_equal 32_000, load_workflow_with("context_window" => "medium")[:context_window]
    assert_equal 128_000, load_workflow_with("context_window" => "full")[:context_window]
  end

  def test_context_window_accepts_an_integer_verbatim
    assert_equal 60_000, load_workflow_with("context_window" => 60_000)[:context_window]
  end

  def test_context_window_defaults_to_medium
    assert_equal 32_000, load_workflow_with({})[:context_window]
  end

  def test_unknown_context_window_word_falls_back_to_medium
    assert_equal 32_000, load_workflow_with("context_window" => "enormous")[:context_window]
  end

  def test_reserve_and_keep_recent_have_defaults
    wf = load_workflow_with({})

    assert_equal 16_384, wf[:reserve_tokens]
    assert_equal 20_000, wf[:keep_recent_tokens]
  end

  def test_reserve_and_keep_recent_are_overridable
    wf = load_workflow_with("reserve_tokens" => 4_000, "keep_recent_tokens" => 5_000)

    assert_equal 4_000, wf[:reserve_tokens]
    assert_equal 5_000, wf[:keep_recent_tokens]
  end
```

Add this helper, following `test_loader.rb`'s existing `with_tmp_project` + write-YAML pattern:

```ruby
  def load_workflow_with(overrides)
    with_tmp_project do
      config = { "name" => "budget_test",
                 "steps" => [{ "id" => "a", "input" => "x", "output_var" => "out" }] }.merge(overrides)
      File.write("config/riggs/workflows/budget_test.yml", YAML.dump(config))
      return Riggs::Workflow::Loader.load(path: "config/riggs/workflows/budget_test.yml")
    end
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_loader.rb`
Expected: FAIL — `Expected: 8000 Actual: :short`

- [ ] **Step 3: Implement**

In `lib/riggs/workflow/loader.rb`, add the constant beside `MAX_TURN_PRESETS`:

```ruby
      # Token budgets, replacing the former step-count window. The words are
      # kept so existing workflow YAML keeps parsing, but they now mean tokens.
      CONTEXT_BUDGETS = {
        short: 8_000,
        medium: 32_000,
        full: 128_000
      }.freeze
```

Replace line 26 and add the two new keys:

```ruby
          context_window: normalize_context_window(cfg[:context_window]),
          reserve_tokens: (cfg[:reserve_tokens] || 16_384).to_i,
          keep_recent_tokens: (cfg[:keep_recent_tokens] || 20_000).to_i,
```

Add the class method:

```ruby
      def self.normalize_context_window(raw)
        return raw.to_i if raw.is_a?(Integer)
        return raw.to_i if raw.to_s.match?(/\A\d+\z/)

        CONTEXT_BUDGETS.fetch((raw || :medium).to_s.to_sym, CONTEXT_BUDGETS[:medium])
      end
```

Delete `CONTEXT_LIMITS` from `lib/riggs/workflow/graph_engine.rb:16`. `build_messages` still references it — Task 11 replaces that call. Until then the suite will fail on `NameError`, so **Tasks 8 and 11 land in one commit**. Do Task 11 now if you are working sequentially; if splitting across agents, keep `CONTEXT_LIMITS` until Task 11 and delete it there.

- [ ] **Step 4: Run the loader tests**

Run: `bundle exec ruby -Itest test/test_loader.rb`
Expected: PASS.

- [ ] **Step 5: Commit (with Task 11, or keeping CONTEXT_LIMITS for now)**

```bash
bundle exec rubocop lib/riggs/workflow/loader.rb
git add lib/riggs/workflow/loader.rb test/test_loader.rb
git commit -m "Redefine context_window as a token budget"
```

---

## Task 9: `Riggs::Usage.estimate`

**Files:**
- Modify: `lib/riggs/usage.rb`
- Modify: `test/test_usage.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Riggs::Usage.estimate(messages, anchor: nil, anchored_count: 0) -> Integer`. Consumed by Task 10.

The anchor is `input_tokens` from the most recent measured response — an exact measurement of the prompt that produced it. `anchored_count` is how many messages that prompt contained; anything appended after is estimated at 4 characters per token. With no anchor, the whole array is estimated.

- [ ] **Step 1: Write the failing tests**

```ruby
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
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_usage.rb`
Expected: FAIL — `NoMethodError: undefined method 'estimate'`

- [ ] **Step 3: Implement**

Add to `lib/riggs/usage.rb` inside `module Usage`:

```ruby
    CHARS_PER_TOKEN = 4

    # Estimates the token size of a message array that has not been sent yet.
    #
    # `anchor` is input_tokens from the most recent measured response, an exact
    # count of the prompt that produced it; `anchored_count` is how many of
    # these messages that prompt contained. Messages beyond that are estimated.
    # The reserve in the compaction ceiling absorbs the error.
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

    private_class_method :heuristic
```

Add `require "json"` at the top of `lib/riggs/usage.rb`.

- [ ] **Step 4: Run and watch them pass**

Run: `bundle exec ruby -Itest test/test_usage.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/riggs/usage.rb
git add lib/riggs/usage.rb test/test_usage.rb
git commit -m "Add Usage.estimate for pre-flight context sizing"
```

---

## Task 10: `Workflow::Compactor`

**Files:**
- Create: `lib/riggs/workflow/compactor.rb`
- Create: `test/test_compactor.rb`
- Modify: `lib/riggs/workflow/graph_engine.rb` (add `require_relative "compactor"`)

**Interfaces:**
- Consumes: `Usage.estimate` (Task 9), `ModelInfo.context_window` (Task 2), `Router#call` (Task 4).
- Produces:
  - `Compactor.new(router:, chain:, budget:, reserve:, keep_recent:, model_overrides: {}, record_call: nil, audit: nil)`
  - `#ceiling(model:) -> Integer`
  - `#over_budget?(messages, model:, anchor: nil, anchored_count: 0) -> Boolean`
  - `#compact(messages:, step_key:, model:) -> Hash` with `:messages`, `:strategy` (`"summarized"` or `"truncated"`), `:before`, `:after`, `:collapsed`
  - Consumed by Tasks 11 and 12.

**Tool-call grouping is the subtle part.** An assistant turn carrying `tool_calls` and the `tool` turns answering it must never be separated — a provider receiving orphaned `tool` results without their originating call rejects the request. The boundary walks backwards past any leading `tool` messages until it sits on a safe split point.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/test_compactor.rb
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

  def test_compact_truncates_when_summarization_fails
    failing = Object.new
    def failing.call(**) = raise(Riggs::Providers::Error, "boom")

    compactor = Riggs::Workflow::Compactor.new(
      router: failing, chain: ["mock"], budget: 1_000, reserve: 100, keep_recent: 200
    )
    messages = 10.times.map { |i| { role: "user", content: "msg#{i} #{'x' * 400}" } }

    result = compactor.compact(messages: messages, step_key: "s", model: nil)

    assert_equal "truncated", result[:strategy]
    assert_operator result[:messages].length, :<, messages.length
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
end
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_compactor.rb`
Expected: FAIL — `NameError: uninitialized constant Riggs::Workflow::Compactor`

- [ ] **Step 3: Implement**

```ruby
# lib/riggs/workflow/compactor.rb
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
        result = @router.call(
          chain: @chain,
          messages: [{ role: "user", content: "#{SUMMARY_PROMPT}\n\n#{transcript}" }],
          timeout: 60
        )
        record(result, step_key)
        result[:content].to_s
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
```

- [ ] **Step 4: Run and watch them pass**

Run: `bundle exec ruby -Itest test/test_compactor.rb`
Expected: PASS, 10 runs, 0 failures.

If `test_compact_never_orphans_tool_results` fails, `safe_boundary` is the code to fix — not the test.

- [ ] **Step 5: Commit**

```ruby
# lib/riggs/workflow/graph_engine.rb, with the other require_relative lines
require_relative "compactor"
```

```bash
bundle exec rubocop lib/riggs/workflow/compactor.rb test/test_compactor.rb
git add lib/riggs/workflow/compactor.rb test/test_compactor.rb lib/riggs/workflow/graph_engine.rb
git commit -m "Add Workflow::Compactor with summarize-or-truncate strategy"
```

---

## Task 11: Cross-step history compaction in GraphEngine

**Files:**
- Modify: `lib/riggs/workflow/graph_engine.rb:16` (delete `CONTEXT_LIMITS`), `:314-320` (`build_messages`)
- Modify: `test/test_graph_engine.rb`

**Interfaces:**
- Consumes: `Compactor` (Task 10), `workflow[:context_window]` etc. (Task 8), `record_provider_call` (Task 6).
- Produces: nothing consumed downstream.

**Selection order and emission order are opposite.** The walk goes newest→oldest to decide what fits, but the returned array must stay oldest-first. Reversing it scrambles the conversation the provider sees.

- [ ] **Step 1: Write the failing tests**

```ruby
  def test_build_messages_keeps_all_outputs_under_budget
    engine = engine_with(context_window: 128_000)
    engine.instance_variable_set(:@outputs, { first: "a" * 100, second: "b" * 100 })

    messages = engine.send(:build_messages, "next input")

    assert_equal 3, messages.length, "two history turns plus the new user turn"
    assert_equal "user", messages.last[:role]
  end

  def test_build_messages_drops_oldest_outputs_over_budget
    engine = engine_with(context_window: 100, reserve_tokens: 0)
    engine.instance_variable_set(:@outputs, { first: "a" * 4_000, second: "b" * 4_000 })

    messages = engine.send(:build_messages, "next input")

    assert_operator messages.length, :<, 3
  end

  def test_build_messages_returns_history_oldest_first
    engine = engine_with(context_window: 128_000)
    engine.instance_variable_set(:@outputs, { first: "OLDEST", second: "NEWEST" })

    contents = engine.send(:build_messages, "input").map { |m| m[:content] }

    assert_operator contents.index("OLDEST"), :<, contents.index("NEWEST"),
                    "history must stay chronological even though selection walks backwards"
  end
```

Write `engine_with` following how the existing tests in that file construct a `GraphEngine` — most build a workflow hash and pass a tmp `db_path`. Read the file and reuse its helper if one exists.

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_graph_engine.rb`
Expected: FAIL — `NameError: uninitialized constant CONTEXT_LIMITS` once Task 8 deleted it, or an assertion failure on the budget tests if it is still present.

- [ ] **Step 3: Implement**

Delete line 16 (`CONTEXT_LIMITS = ...`) if Task 8 left it in place.

Replace `build_messages`:

```ruby
      # Selects prior step outputs by token budget rather than step count.
      # The walk is newest-to-oldest so the most recent context survives, but
      # the emitted array is chronological — a provider reading it in selection
      # order would see the conversation backwards.
      def build_messages(resolved_input)
        ceiling = compactor.ceiling(model: nil)
        vars = @workflow[:steps].map(&:output_var).map(&:to_sym).select { |k| @outputs.key?(k) }

        kept = []
        used = Usage.estimate([{ role: "user", content: resolved_input }])
        vars.reverse_each do |var|
          turn = { role: "assistant", content: @outputs[var].to_s }
          size = Usage.estimate([turn])
          break if used + size > ceiling

          used += size
          kept.unshift(turn)
        end

        kept + [{ role: "user", content: resolved_input }]
      end

      def compactor
        @compactor ||= Compactor.new(
          router: @router,
          chain: @router.chain_for(step: @workflow[:steps].first, workflow: @workflow),
          budget: @workflow[:context_window],
          reserve: @workflow[:reserve_tokens],
          keep_recent: @workflow[:keep_recent_tokens],
          record_call: method(:record_provider_call)
        )
      end
```

Add `require_relative "../usage"` at the top of `graph_engine.rb` if not already present via `compactor.rb`.

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rake test`
Expected: PASS. Existing workflow tests will now retain more history than before — that is the intended behavior change from Task 8, not a regression. If a test asserts a specific message count from the old step-count window, update it and note the change in the commit message.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop
git add lib/riggs/workflow/graph_engine.rb test/test_graph_engine.rb
git commit -m "Budget cross-step history by tokens instead of step count"
```

---

## Task 12: Intra-step compaction in ToolLoop

**Files:**
- Modify: `lib/riggs/workflow/tool_loop.rb` (constructor, `run` loop)
- Modify: `lib/riggs/workflow/graph_engine.rb:194-206` (pass the compactor)
- Modify: `test/test_tool_loop.rb`

**Interfaces:**
- Consumes: `Compactor` (Task 10).
- Produces: `ToolLoop.new(..., compactor: nil)`. Nothing consumes it downstream.

This is the site that is currently trimmed by nothing at all. `messages` grows with every assistant turn and every tool result until the provider rejects the request.

- [ ] **Step 1: Write the failing tests**

```ruby
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

  def test_no_compaction_without_a_compactor
    loop_runner = build_loop(compactor: nil)

    result = loop_runner.run(step: build_step, chain: ["mock"],
                             messages: [{ role: "user", content: "hi" }],
                             system_prompt: "sys", io: StringIO.new)

    refute_nil result[:content]
  end
```

Add a `build_loop` helper to the class:

```ruby
  def build_loop(compactor: nil, audit: ->(**) {})
    Riggs::Workflow::ToolLoop.new(
      router: Riggs::Providers::Router.new(hub_providers: { mock: { type: "mock" } }),
      mcp_manager: nil, skill_registry: nil, audit: audit, compactor: compactor,
      llm_calls: 0, max_llm_calls: 5, timeout_seconds: 60,
      started_at: Time.now, session_id: "sess-1"
    )
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_tool_loop.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :compactor`

- [ ] **Step 3: Implement**

Add `compactor: nil` to the `ToolLoop` constructor keywords and `@compactor = compactor`.

In `run`, immediately after `check_guardrails!` and before `@router.call`:

```ruby
          compact_if_needed!(messages, step)
```

Add the private method:

```ruby
      # Mutates `messages` in place so the caller's array — which GraphEngine
      # also holds a reference to — reflects the compacted transcript.
      def compact_if_needed!(messages, step)
        return unless @compactor
        return unless @compactor.over_budget?(messages, model: @last_model,
                                              anchor: @anchor_tokens, anchored_count: @anchored_count)

        outcome = @compactor.compact(messages: messages, step_key: step.id, model: @last_model)
        messages.replace(outcome[:messages])
        @anchor_tokens = nil
        @anchored_count = 0
        @audit.call(session_id: @session_id, event_type: "context_compacted",
                    payload: { step: step.id, strategy: outcome[:strategy],
                               before: outcome[:before], after: outcome[:after],
                               collapsed: outcome[:collapsed] })
      end
```

After the `@record_call&.call(...)` block added in Task 6, capture the anchor:

```ruby
          if result[:usage] && result[:usage][:measured]
            @anchor_tokens = result[:usage][:input_tokens]
            @anchored_count = messages.length
          end
          @last_model = result[:model]
```

Initialize the three ivars in the constructor:

```ruby
        @anchor_tokens = nil
        @anchored_count = 0
        @last_model = nil
```

Wire the compactor in `graph_engine.rb`'s `ToolLoop.new` call:

```ruby
            compactor: compactor,
```

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rake test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop
git add lib/riggs/workflow/tool_loop.rb lib/riggs/workflow/graph_engine.rb test/test_tool_loop.rb
git commit -m "Compact the tool loop transcript against the token ceiling"
```

---

## Task 13: Unmeasurable chains, docs, and close-out

**Files:**
- Modify: `lib/riggs/workflow/graph_engine.rb`
- Modify: `test/test_graph_engine.rb`
- Modify: `docs/gaps.md`, `CHANGELOG.md`, `README.md`, `docs/token-ledger.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

A run on a CLI-only chain cannot compact, because no provider supplies the anchor. Silent non-compaction is indistinguishable from compaction that is working, so it is announced once.

- [ ] **Step 1: Write the failing test**

```ruby
  def test_cli_only_chain_audits_compaction_unavailable
    engine = engine_with(context_window: 32_000, chain: ["claude_cli"])

    engine.send(:announce_compaction_availability!, ["claude_cli"])
    events = engine.audit_log.map { |e| e[:event_type] }

    assert_includes events, "compaction_unavailable"
  end

  def test_measurable_chain_does_not_announce
    engine = engine_with(context_window: 32_000, chain: ["mock"])

    engine.send(:announce_compaction_availability!, ["mock"])

    refute_includes engine.audit_log.map { |e| e[:event_type] }, "compaction_unavailable"
  end

  def test_announcement_happens_only_once
    engine = engine_with(context_window: 32_000, chain: ["claude_cli"])

    3.times { engine.send(:announce_compaction_availability!, ["claude_cli"]) }

    assert_equal 1, engine.audit_log.count { |e| e[:event_type] == "compaction_unavailable" }
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `bundle exec ruby -Itest test/test_graph_engine.rb`
Expected: FAIL — `NoMethodError: undefined method 'announce_compaction_availability!'`

- [ ] **Step 3: Implement**

Add to `graph_engine.rb`. Reuse the provider name list already in `ToolLoop#cli_only_chain?` (`tool_loop.rb:162`) rather than writing a second copy — move it to a shared constant on `Riggs::Providers::Router` and have both reference it.

```ruby
      # No provider on this chain reports usage, so there is no anchor and
      # compaction can never trigger. Announced once per run: silent
      # non-compaction looks exactly like compaction that is working.
      def announce_compaction_availability!(chain)
        return if @compaction_announced
        return unless Providers::Router.unmetered_chain?(chain)

        @compaction_announced = true
        log_event("compaction_unavailable", { chain: Array(chain).map(&:to_s) })
      end
```

On `Providers::Router`:

```ruby
      # Providers that return no token usage, so nothing downstream can measure
      # or compact a conversation running on them.
      UNMETERED = %w[cursor cursor_cli cursor_cloud claude_cli anthropic_cli codex openai_cli cli].freeze

      def self.unmetered_chain?(chain)
        names = Array(chain).map(&:to_s)
        !names.empty? && names.all? { |n| UNMETERED.include?(n) }
      end
```

Call it in `run_steps`, right after `chain = @router.chain_for(...)`:

```ruby
          announce_compaction_availability!(chain)
```

Update `ToolLoop#cli_only_chain?` to delegate:

```ruby
      def cli_only_chain?(chain)
        Providers::Router.unmetered_chain?(chain)
      end
```

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rake test`
Expected: PASS.

Note `cli_only_chain?` previously excluded `cli` and `cursor_cloud` from its list. Delegating widens it, which means the TOOL: prompt suffix now also goes to those providers — correct, since neither supports native tool calling. Confirm `test_tool_loop.rb` still passes.

- [ ] **Step 5: Update the docs**

In `docs/gaps.md`:
- Move `#2` and `#3` into the shipped list at the top, struck through, pointing at `specs/phase7-token-accounting-and-compaction.md`.
- Delete the "Done when: ... and the ledger fills itself" line, replacing it with the corrected statement from the spec's Motivation section.
- Update the intro sentence — "The five below are open" becomes three.
- In "Not adopting from Pi", the MCP bullet says "#2 would let this be measured rather than assumed." Change it to state that measurement now exists and name the surface (`riggs workflow:inspect`).

In `README.md`, document the three workflow keys with their defaults and the units:

```yaml
context_window: medium      # short | medium | full | an integer token budget
reserve_tokens: 16384       # headroom for estimation error
keep_recent_tokens: 20000   # recent turns kept verbatim when compacting
```

Also document the `.agent_hubrc` `pricing:` and `context_windows:` override blocks under the providers section, and note `Riggs::ModelInfo::AS_OF`.

In `CHANGELOG.md`, add an entry covering token accounting, cost estimation, and compaction, and call out the behavior change: `context_window` now means tokens, not steps.

In `docs/token-ledger.md`, add the Phase 7 row per the protocol at the top of that file.

- [ ] **Step 6: Final verification**

```bash
bundle exec rubocop
bundle exec rake test
bundle exec exe/riggs workflow:run example_triage
bundle exec exe/riggs workflow:inspect <session-id>
```

Confirm by eye: the inspect output shows tokens with coverage, and a mock-only run shows a priced or unpriced total consistent with whether `mock` has a price entry.

- [ ] **Step 7: Commit**

```bash
git add docs CHANGELOG.md README.md lib test
git commit -m "Announce unmeasurable chains; document Phase 7 and close gaps #2 and #3"
```

---

## Definition of done

Checked against the spec's own list:

1. A completed run reports tokens in/out and cost per step and per session, each with coverage on both counters — Tasks 5, 7.
2. Unmeasured providers render as unmeasured everywhere, never as zero — Tasks 1, 5, 7.
3. A run exceeding the ceiling compacts instead of erroring, at both sites — Tasks 11, 12.
4. Compaction's own token cost is recorded like any other call — Task 10.
5. `docs/gaps.md` #2 and #3 struck through, and #2's ledger line corrected — Task 13.
6. Full suite green, RuboCop clean, pre-commit gate passing — every task.

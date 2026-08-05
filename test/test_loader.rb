# frozen_string_literal: true

require "test_helper"

class TestLoader < Minitest::Test
  def test_loads_example_triage
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      assert_equal "example_triage", workflow[:name]
      assert_equal 4, workflow[:steps].size
      assert workflow[:steps][1].approval_gate?
    end
  end

  def test_validate_ok
    with_tmp_project do
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/example_triage.yml")
      report = Riggs::Workflow::Loader.validate(workflow)
      assert report[:valid], report[:errors].inspect
    end
  end

  def test_detects_cycle
    with_tmp_project do
      File.write("config/riggs/workflows/cyclic.yml", <<~YAML)
        name: cyclic
        steps:
          - id: a
            input: "x"
            next: b
          - id: b
            input: "y"
            next: a
      YAML
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/cyclic.yml")
      report = Riggs::Workflow::Loader.validate(workflow)
      refute report[:valid]
      assert report[:errors].any? { |e| e.include?("Cycle") }
    end
  end

  def test_missing_ref
    with_tmp_project do
      File.write("config/riggs/workflows/bad_ref.yml", <<~YAML)
        name: bad_ref
        steps:
          - id: a
            input: "x"
            next: missing_step
      YAML
      workflow = Riggs::Workflow::Loader.load(path: "config/riggs/workflows/bad_ref.yml")
      report = Riggs::Workflow::Loader.validate(workflow)
      refute report[:valid]
      assert report[:errors].any? { |e| e.include?("undefined") }
    end
  end

  def test_resolve_context
    out = Riggs::Workflow::Loader.resolve_context(
      "Ticket={{workflow.input.ticket}} Class={{workflow.classify.classification}}",
      { input: { ticket: "T1" }, classify: { classification: "ERROR" } }
    )
    assert_equal "Ticket=T1 Class=ERROR", out
  end

  def test_next_contains_branch
    step = Riggs::Workflow::StepNode.from_hash(
      id: "c",
      next: "if contains ERROR: debug; else: summarize"
    )
    assert_equal "debug", Riggs::Workflow::Loader.resolve_next(step, outputs: { "c_result" => "foo ERROR bar" })
    assert_equal "summarize", Riggs::Workflow::Loader.resolve_next(step, outputs: { "c_result" => "all good" })
  end

  def test_unmet_conditional_next_without_else_ends_workflow
    step = Riggs::Workflow::StepNode.from_hash(id: "c", next: "if contains ERROR: escalate")
    assert_nil Riggs::Workflow::Loader.resolve_next(step, outputs: { "c_result" => "classification=OK" })
  end

  def test_unmet_gate_conditional_next_ends_workflow
    step = Riggs::Workflow::StepNode.from_hash(id: "g", next: "if gate.approved: deploy")
    assert_nil Riggs::Workflow::Loader.resolve_next(step, outputs: {}, gate_decision: :rejected)
  end

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

  def load_workflow_with(overrides)
    with_tmp_project do
      config = { "name" => "budget_test",
                 "steps" => [{ "id" => "a", "input" => "x", "output_var" => "out" }] }.merge(overrides)
      File.write("config/riggs/workflows/budget_test.yml", YAML.dump(config))
      return Riggs::Workflow::Loader.load(path: "config/riggs/workflows/budget_test.yml")
    end
  end
end

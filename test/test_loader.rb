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
end

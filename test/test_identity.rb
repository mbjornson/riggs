# frozen_string_literal: true

require "test_helper"

class TestIdentity < Minitest::Test
  def test_resolve_engineer
    with_tmp_project do
      identity = Riggs::Identity.resolve(cli_user: "eng_bob")
      assert_equal "eng_bob", identity[:id]
      assert_equal :engineer, identity[:role]
      assert_includes identity[:permissions], "run_workflow"
      assert_includes identity[:permissions], "approve_gates"
    end
  end

  def test_viewer_lacks_run
    with_tmp_project do
      identity = Riggs::Identity.resolve(cli_user: "view_cara")
      refute_includes identity[:permissions], "run_workflow"
      assert_includes identity[:permissions], "inspect_run"
    end
  end

  def test_unknown_user
    with_tmp_project do
      assert_raises(Riggs::Error) { Riggs::Identity.resolve(cli_user: "nope") }
    end
  end

  def test_permitted
    with_tmp_project do
      id = Riggs::Identity.resolve(cli_user: "pm_alice")
      assert Riggs::Identity.permitted?(id, "edit_workflow")
      refute Riggs::Identity.permitted?(id, "run_workflow")
    end
  end
end

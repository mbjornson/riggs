# frozen_string_literal: true

require "test_helper"
require "timeout"

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

  # Psych auto-types an unquoted date. permitted_classes must include Date
  # or a routine field raises Psych::DisallowedClass out of load_config.
  def test_load_config_untrusted_accepts_a_date_field
    Dir.mktmpdir("riggs-identity") do |dir|
      path = File.join(dir, ".agent_hubrc")
      File.write(path, <<~YAML)
        default_user: bob
        created: 2026-08-05
        users:
          bob:
            role: engineer
      YAML

      cfg = Riggs::Identity.load_config_untrusted(path)

      assert_equal "bob", cfg[:default_user]
      assert_equal Date.new(2026, 8, 5), cfg[:created]
    end
  end

  def alias_bomb_hubrc
    lines = []
    prev = nil
    10.times do |i|
      key = "a#{i}"
      lines << if prev.nil?
                 "#{key}: &#{key} [\"leaf\"]"
               else
                 "#{key}: &#{key} [#{Array.new(9) { "*#{prev}" }.join(', ')}]"
               end
      prev = key
    end
    lines << "default_user: *#{prev}"
    "#{lines.join("\n")}\n"
  end

  # Aliases are disabled so Psych raises before deep_symbolize can expand
  # shared references into a hang. The error must be a Riggs::Error the
  # caller can report, not a raw Psych exception.
  def test_load_config_untrusted_rejects_yaml_aliases_without_hanging
    Dir.mktmpdir("riggs-identity") do |dir|
      path = File.join(dir, ".agent_hubrc")
      File.write(path, alias_bomb_hubrc)

      error = nil
      Timeout.timeout(10) do
        error = assert_raises(Riggs::Error) do
          Riggs::Identity.load_config_untrusted(path)
        end
      end

      refute_kind_of Psych::Exception, error
      refute_empty error.message
      assert_match(/alias|Invalid|\.agent_hubrc|Psych/i, error.message)
    end
  end
end

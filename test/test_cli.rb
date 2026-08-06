# frozen_string_literal: true

require "test_helper"

class TestCLI < Minitest::Test
  def test_setup_preserves_existing_agent_hubrc
    with_tmp_project do
      File.write(".agent_hubrc", <<~YAML)
        default_user: custom_marker_user
        users:
          custom_marker_user:
            id: custom_marker_user
            role: pm
      YAML
      capture_io { Riggs::CLI.start(["setup"]) }
      assert_includes File.read(".agent_hubrc"), "custom_marker_user",
                      "setup must not overwrite an existing .agent_hubrc"
    end
  end

  def test_workflow_run_warns_when_mcp_config_is_broken
    with_tmp_project do
      File.write(".agent_hubrc", "#{File.read('.agent_hubrc')}mcp_servers: totally_not_a_hash\n")
      out, err = capture_io do
        Riggs::CLI.start(
          ["workflow:run", "example_triage", "--auto-approve", "--ticket", "Password reset request"]
        )
      end
      assert_match(/completed/i, out)
      assert_match(/MCP/i, err, "a broken mcp_servers config must produce a warning")
    end
  end

  def test_memory_recall_denied_for_viewer
    with_tmp_project do
      assert_raises(SystemExit, "viewer without memory permissions must be denied recall") do
        capture_io { Riggs::CLI.start(["memory:recall", "anything", "--user", "view_cara"]) }
      end
    end
  end

  def test_memory_recall_allowed_for_engineer
    with_tmp_project do
      out, = capture_io { Riggs::CLI.start(["memory:recall", "anything", "--user", "eng_bob"]) }
      assert_match(/Memory Recall/i, out)
    end
  end

  def test_skills_show_prints_the_description
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/writer")
      File.write("config/riggs/skills/writer/SKILL.md",
                 "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      out = capture_io { Riggs::CLI.start(%w[skills:show writer]) }.first

      assert_match(/Writes clearly\./, out)
    end
  end

  def test_skills_list_prints_the_description
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/writer")
      File.write("config/riggs/skills/writer/SKILL.md",
                 "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      out = capture_io { Riggs::CLI.start(%w[skills:list]) }.first

      assert_match(/writer/, out)
      assert_match(/Writes clearly\./, out)
    end
  end

  def test_skills_list_omits_the_separator_when_description_is_absent
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/plain")
      File.write("config/riggs/skills/plain/SKILL.md", "---\nname: plain\n---\nBody.\n")

      out = capture_io { Riggs::CLI.start(%w[skills:list]) }.first

      plain_line = out.lines.find { |line| line.include?("plain") }
      refute_nil plain_line, "expected a line listing the 'plain' skill in:\n#{out}"
      refute_includes plain_line, "—",
                      "a skill with no description must not render a dangling em-dash separator"
    end
  end

  def test_skills_show_has_no_blank_line_when_description_is_absent
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/plain")
      File.write("config/riggs/skills/plain/SKILL.md",
                 "---\nname: plain\nsystem_prompt: Be helpful.\n---\n")

      out = capture_io { Riggs::CLI.start(%w[skills:show plain]) }.first

      lines = out.lines
      header_index = lines.index { |line| line.include?("SKILL PLAIN") }
      refute_nil header_index, "expected a header line for the 'plain' skill in:\n#{out}"
      # lines[header_index + 1] is the "────" separator printed by
      # print_header; the next line must be the system prompt itself, not a
      # stray blank line left behind by an unconditional description puts.
      assert_equal "Be helpful.\n", lines[header_index + 2]
    end
  end
end

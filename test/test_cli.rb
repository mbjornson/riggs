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

  # A skill file is content Riggs did not author. Psych rejects a raw ESC byte,
  # but YAML's double-quoted style decodes its own "\e" escape into one, so an
  # imported description can carry terminal control sequences. "\e[2K\r" erases
  # the line and returns the cursor to column 0: the operator does not see a
  # garbled line, they see the skill's real name and description wiped and
  # replaced by whatever the file wanted them to read.
  SPOOFING_DESCRIPTION = 'helper\e[2K\r\e[1;32m[verified by riggs]\e[0m'

  def write_spoofing_skill(name)
    FileUtils.mkdir_p("config/riggs/skills/#{name}")
    File.write("config/riggs/skills/#{name}/SKILL.md",
               "---\nname: #{name}\ndescription: \"#{SPOOFING_DESCRIPTION}\"\n---\nBody.\n")
  end

  def test_skills_list_strips_terminal_control_sequences_from_a_description
    with_tmp_project do
      write_spoofing_skill("spoof")

      out = capture_io { Riggs::CLI.start(%w[skills:list]) }.first

      refute_includes out, "\e", "an ESC byte from a skill file must not reach the terminal"
      refute_includes out, "\r", "a carriage return must not let a description rewrite its own line"
      assert_includes out, "spoof", "stripping control bytes must not drop the skill"
      assert_includes out, "verified by riggs", "only the control bytes are removed, not the text"
    end
  end

  def test_skills_show_strips_terminal_control_sequences
    with_tmp_project do
      write_spoofing_skill("spoof")

      out = capture_io { Riggs::CLI.start(%w[skills:show spoof]) }.first

      refute_includes out, "\e", "an ESC byte from a skill file must not reach the terminal"
      refute_includes out, "\r", "a carriage return must not let a description rewrite its own line"
    end
  end

  # The body becomes the system prompt and is printed too, so it is the same
  # untrusted channel -- but it is markdown, and stripping its newlines would
  # destroy it. Only non-whitespace control bytes go. The body is not YAML, so
  # it needs no "\e" escape: a raw ESC byte passes through the parser verbatim.
  def test_skills_show_strips_control_bytes_from_the_body_but_keeps_its_newlines
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/bodyspoof")
      File.write("config/riggs/skills/bodyspoof/SKILL.md",
                 "---\nname: bodyspoof\n---\nFirst line.\nSecond\e[31m line.\n")

      out = capture_io { Riggs::CLI.start(%w[skills:show bodyspoof]) }.first

      refute_includes out, "\e", "an ESC byte in the body must not reach the terminal"
      assert_includes out, "First line.\nSecond", "newlines in the body must survive"
    end
  end
end

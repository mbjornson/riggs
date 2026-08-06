# frozen_string_literal: true

require "test_helper"
require "fileutils"

class TestSkills < Minitest::Test
  def test_load_latest_and_pin
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/triage_v1_old")
      File.write("config/riggs/skills/triage_v1_old/SKILL.yml", <<~YAML)
        name: triage_v1
        version: "0.9.0"
        system_prompt: old
        tools: []
      YAML

      reg = Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
      latest = reg.load("triage_v1")
      assert_equal "1.0.0", latest[:version]
      assert latest[:tools].any? { |t| t[:name] == "lookup_runbook" }

      pinned = reg.load("triage_v1@0.9.0")
      assert_equal "0.9.0", pinned[:version]
      assert_equal "old", pinned[:system_prompt]

      assert_nil reg.load("triage_v1@9.9.9")
    end
  end

  def test_list_includes_versions
    with_tmp_project do
      reg = Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
      names = reg.list.map { |s| s[:name] }
      assert_includes names, "triage_v1"
    end
  end

  def write_skill_md(dir, contents)
    FileUtils.mkdir_p("config/riggs/skills/#{dir}")
    File.write("config/riggs/skills/#{dir}/SKILL.md", contents)
  end

  def registry
    Riggs::SkillRegistry.new(roots: ["./config/riggs/skills"])
  end

  def test_loads_a_skill_from_skill_md_with_the_body_as_the_prompt
    with_tmp_project do
      write_skill_md("writer", "---\nname: writer\n---\nWrite clearly. Cite sources.\n")

      skill = registry.load("writer")

      refute_nil skill, "a SKILL.md directory must be discoverable"
      assert_equal "Write clearly. Cite sources.\n", skill[:system_prompt]
    end
  end

  # Same key space in both containers: an imported skill can gain a tool
  # without being converted to SKILL.yml.
  def test_tools_declared_in_skill_md_frontmatter_are_normalized
    with_tmp_project do
      write_skill_md("searcher", <<~MD)
        ---
        name: searcher
        tools:
          - name: search_issues
            description: Search known issues.
            mcp_server: github
            input_schema:
              type: object
              properties:
                query:
                  type: string
        ---
        Search before answering.
      MD

      tool = registry.load("searcher")[:tools].first

      assert_equal "search_issues", tool[:name]
      assert_equal "github", tool[:mcp_server]
      assert_equal "object", tool[:input_schema][:type]
    end
  end

  def test_a_version_in_skill_md_frontmatter_can_be_pinned
    with_tmp_project do
      write_skill_md("pinned", "---\nname: pinned\nversion: \"2.1.0\"\n---\nBody.\n")

      assert_equal "2.1.0", registry.load("pinned")[:version]
      assert_equal "2.1.0", registry.load("pinned@2.1.0")[:version]
      assert_nil registry.load("pinned@9.9.9")
    end
  end

  def test_a_skill_md_without_a_name_falls_back_to_its_directory
    with_tmp_project do
      write_skill_md("unnamed", "---\ndescription: No name key.\n---\nBody.\n")

      assert_equal "unnamed", registry.load("unnamed")[:name]
    end
  end

  # Adding SKILL.md support must not change how any skill that exists today
  # behaves, so the native container wins and nothing is announced.
  def test_skill_yml_wins_when_both_files_exist
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/both")
      File.write("config/riggs/skills/both/SKILL.yml", "name: both\nsystem_prompt: from yml\n")
      File.write("config/riggs/skills/both/SKILL.md", "---\nname: both\n---\nfrom md\n")

      assert_equal "from yml", registry.load("both")[:system_prompt]
    end
  end

  # The existing rule -- an explicit key beats a file -- is preserved, with the
  # markdown body slotted in between the key and prompt.md.
  def test_an_explicit_system_prompt_key_beats_the_markdown_body
    with_tmp_project do
      write_skill_md("explicit", "---\nname: explicit\nsystem_prompt: from key\n---\nfrom body\n")

      assert_equal "from key", registry.load("explicit")[:system_prompt]
    end
  end

  def test_a_skill_md_with_an_empty_body_falls_back_to_prompt_md
    with_tmp_project do
      write_skill_md("fallback", "---\nname: fallback\n---\n")
      File.write("config/riggs/skills/fallback/prompt.md", "from prompt.md")

      assert_equal "from prompt.md", registry.load("fallback")[:system_prompt]
    end
  end

  def test_list_includes_skill_md_bundles
    with_tmp_project do
      write_skill_md("writer", "---\nname: writer\n---\nBody.\n")

      assert_includes registry.list_names, "writer"
    end
  end

  def test_description_reaches_the_loaded_skill
    with_tmp_project do
      write_skill_md("writer", "---\nname: writer\ndescription: Writes clearly.\n---\nBody.\n")

      assert_equal "Writes clearly.", registry.load("writer")[:description]
    end
  end

  # One key space in two containers: description works in SKILL.yml too.
  def test_description_works_in_skill_yml_as_well
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/ymldesc")
      File.write("config/riggs/skills/ymldesc/SKILL.yml", "name: ymldesc\ndescription: From yaml.\nsystem_prompt: x\n")

      assert_equal "From yaml.", registry.load("ymldesc")[:description]
    end
  end

  def test_a_skill_without_a_description_reports_an_empty_string
    with_tmp_project do
      write_skill_md("plain", "---\nname: plain\n---\nBody.\n")

      assert_equal "", registry.load("plain")[:description]
    end
  end

  # list groups by name across versions; the description shown must be the one
  # belonging to the version list also reports as `latest`.
  def test_list_reports_the_newest_versions_description
    with_tmp_project do
      write_skill_md("multi@1.0.0", "---\nname: multi\nversion: \"1.0.0\"\ndescription: old one\n---\nB.\n")
      write_skill_md("multi@2.0.0", "---\nname: multi\nversion: \"2.0.0\"\ndescription: new one\n---\nB.\n")

      row = registry.list.find { |s| s[:name] == "multi" }

      assert_equal "2.0.0", row[:latest]
      assert_equal "new one", row[:description]
    end
  end

  # One bad directory -- often imported from someone else's repository --
  # must not take down every command that touches the registry.
  def test_a_malformed_skill_md_is_skipped_and_its_neighbour_still_loads
    with_tmp_project do
      write_skill_md("broken", "---\nname: [unclosed\n---\nBody.\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      stdout, stderr = capture_io { names = registry.list_names }

      assert_includes names, "healthy"
      refute_includes names, "broken"
      assert_match(/skipping skill/, stderr)
      assert_match(%r{config/riggs/skills/broken}, stderr)
      assert_empty stdout
    end
  end

  def test_a_malformed_skill_md_does_not_break_loading_another_skill
    with_tmp_project do
      write_skill_md("broken", "---\nname: [unclosed\n---\nBody.\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nGood body.\n")

      skill = nil
      capture_io { skill = registry.load("healthy") }

      refute_nil skill
      assert_equal "Good body.\n", skill[:system_prompt]
    end
  end

  # Non-mapping frontmatter raises ArgumentError from the parser; that is a
  # malformed file, not a crash.
  def test_a_skill_md_with_non_mapping_frontmatter_is_skipped
    with_tmp_project do
      write_skill_md("listy", "---\n- one\n- two\n---\nBody.\n")

      names = nil
      capture_io { names = registry.list_names }

      refute_includes names, "listy"
    end
  end

  # The same posture applies to the native container. Today a malformed
  # SKILL.yml raises out of #list and takes down every command that touches
  # the registry, including runs that wanted a different skill entirely.
  def test_a_malformed_skill_yml_is_skipped_too
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/badyml")
      File.write("config/riggs/skills/badyml/SKILL.yml", "name: [unclosed\n")

      names = nil
      capture_io { names = registry.list_names }

      assert_includes names, "triage_v1", "the bundled skill must still load"
      refute_includes names, "badyml"
    end
  end

  # The mapping guard applies to the native container too: a SKILL.yml that
  # parses to a list or scalar must not crash sibling skills either.
  def test_a_skill_yml_with_non_mapping_content_is_skipped
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/listy")
      File.write("config/riggs/skills/listy/SKILL.yml", "- one\n- two\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      capture_io { names = registry.list_names }

      refute_includes names, "listy"
      assert_includes names, "healthy"
    end
  end
end

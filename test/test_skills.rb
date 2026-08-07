# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "timeout"

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

  # The whole point of the feature: a file written for another harness, with no
  # Riggs-specific keys, copied in and used verbatim. Asserting on the system
  # prompt the PROVIDER received proves the body actually reached the model,
  # rather than merely that the registry parsed something.
  def test_an_off_the_shelf_skill_md_drives_a_workflow_step_unmodified
    with_tmp_project do
      write_skill_md("code-reviewer", <<~MD)
        ---
        name: code-reviewer
        description: Reviews a diff for correctness and clarity.
        ---
        # Code Reviewer

        Review the diff. Report correctness problems before style ones.

        ---

        Always name the file and line.
      MD

      captured = []
      capturing = Class.new(Riggs::Providers::Base) do
        define_method(:complete) do |system: nil, **|
          captured << system.to_s
          { provider: name, model: nil, content: "reviewed", tool_calls: [], usage: {} }
        end
      end
      router = Riggs::Providers::Router.new(
        hub_providers: { cap: { type: "cap" } }, registry: { "cap" => capturing }
      )

      workflow = {
        name: "review_flow",
        context_window: 32_000, reserve_tokens: 16_384, keep_recent_tokens: 20_000,
        max_llm_calls: 5, timeout_seconds: 60,
        providers: { default: { relay_chain: ["cap"] } },
        steps: [Riggs::Workflow::StepNode.from_hash(
          "id" => "review", "input" => "Review this.", "output_var" => "review",
          "skill" => "code-reviewer"
        )]
      }
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: { id: "eng_bob", memory_namespace: "eng_bob_private" },
        db_path: "./db/riggs.sqlite3",
        provider_router: router,
        skill_registry: registry
      )

      engine.execute(StringIO.new, input: {})

      assert_equal :completed, engine.status
      assert_includes captured.first, "Report correctness problems before style ones.",
                      "the markdown body must reach the model as the step's system prompt"
      assert_includes captured.first, "Always name the file and line.",
                      "content after a horizontal rule is body, not a second frontmatter block"
    end
  end

  # An off-the-shelf SKILL.md is ordinary content, not an attack: an unquoted
  # date-shaped scalar is auto-typed by Psych. It must load, not merely be
  # skipped -- Psych::DisallowedClass previously escaped read_skill_dir's
  # rescue and took down every sibling skill in the registry with it.
  def test_a_skill_md_with_a_date_field_loads_successfully
    with_tmp_project do
      write_skill_md("dated", <<~MD)
        ---
        name: dated
        description: A skill with a date.
        updated: 2026-08-05
        ---
        Body.
      MD

      skill = registry.load("dated")

      refute_nil skill, "a dated SKILL.md must load, not be skipped"
      assert_equal "dated", skill[:name]
      assert_equal "A skill with a date.", skill[:description]
    end
  end

  # The same posture applies to the native container: SKILL.yml shares the
  # fix, not just SKILL.md.
  def test_a_skill_yml_with_a_date_field_loads_successfully
    with_tmp_project do
      FileUtils.mkdir_p("config/riggs/skills/dated_yml")
      File.write("config/riggs/skills/dated_yml/SKILL.yml", <<~YAML)
        name: dated_yml
        description: A yaml skill with a date.
        updated: 2026-08-05
        system_prompt: x
      YAML

      skill = registry.load("dated_yml")

      refute_nil skill, "a dated SKILL.yml must load, not be skipped"
      assert_equal "dated_yml", skill[:name]
      assert_equal "A yaml skill with a date.", skill[:description]
    end
  end

  # Skill files have no legitimate need for YAML anchors. An alias to an
  # anchor that was never defined must be skipped like any other malformed
  # file, not crash the whole registry.
  def test_a_skill_md_with_an_undefined_alias_is_skipped_and_healthy_sibling_still_loads
    with_tmp_project do
      write_skill_md("undefined_anchor", "---\nname: undefined_anchor\ntools: *nope\n---\nBody.\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      stdout, stderr = capture_io { names = registry.list_names }

      refute_includes names, "undefined_anchor"
      assert_includes names, "healthy"
      assert_match(/skipping skill/, stderr)
      assert_empty stdout
    end
  end

  # Aliases are disabled outright, so even a well-formed, self-contained
  # anchor/alias pair is rejected -- not just a broken reference.
  def test_a_skill_md_using_yaml_aliases_is_skipped_and_healthy_sibling_still_loads
    with_tmp_project do
      write_skill_md("aliased", "---\nname: aliased\ntags: &t [a, b]\nmore: *t\n---\nBody.\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      stdout, stderr = capture_io { names = registry.list_names }

      refute_includes names, "aliased"
      assert_includes names, "healthy"
      assert_match(/skipping skill/, stderr)
      assert_empty stdout
    end
  end

  # Billion-laughs shape: nested anchors with ~9-way fan-out over ~10 levels.
  # Psych.safe_load itself stays fast because aliases produce shared
  # references -- the danger was Identity.deep_symbolize walking those shared
  # references and materializing billions of leaf copies. With aliases
  # disabled, Psych raises before any of that expansion happens, so this must
  # complete well within the timeout rather than hang or exhaust memory.
  def alias_bomb_frontmatter
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
    lines << "tools: *#{prev}"
    "---\nname: bomb\n#{lines.join("\n")}\n---\nBody.\n"
  end

  def test_an_alias_bomb_skill_md_does_not_hang
    with_tmp_project do
      write_skill_md("bomb", alias_bomb_frontmatter)
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      stderr = nil
      Timeout.timeout(10) do
        _stdout, stderr = capture_io { names = registry.list_names }
      end

      refute_includes names, "bomb"
      assert_includes names, "healthy"
      assert_match(/skipping skill/, stderr)
    end
  end

  def deeply_nested_flow_yaml(depth)
    ("[" * depth) + ("]" * depth)
  end

  # Psych recurses once per nesting level while composing a document;
  # sufficiently deep flow-style ([...]) nesting overflows the Ruby call
  # stack and raises SystemStackError. Unlike every other Psych failure,
  # SystemStackError descends from Exception, not StandardError, so it
  # would escape read_skill_dir's rescue outright and take every skill in
  # the registry down with it -- defeating R7.5 for every command that
  # touches the registry, not just this one skill. SkillFrontmatter rejects
  # the input before Psych ever sees it, so it is skipped like any other
  # malformed file.
  def test_a_deeply_nested_skill_md_is_skipped_and_healthy_sibling_still_loads
    with_tmp_project do
      depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH * 20
      write_skill_md("deep", "---\nname: deep\nx: #{deeply_nested_flow_yaml(depth)}\n---\nBody.\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      stdout, stderr = capture_io { names = registry.list_names }

      refute_includes names, "deep"
      assert_includes names, "healthy"
      assert_match(/skipping skill/, stderr)
      assert_empty stdout
    end
  end

  # The same vector reaches Psych identically through the native container:
  # SKILL.yml has no frontmatter delimiters, but skill_source hands its
  # contents to the same guarded loader.
  def test_a_deeply_nested_skill_yml_is_skipped_and_healthy_sibling_still_loads
    with_tmp_project do
      depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH * 20
      FileUtils.mkdir_p("config/riggs/skills/deep_yml")
      File.write("config/riggs/skills/deep_yml/SKILL.yml", "name: deep_yml\nx: #{deeply_nested_flow_yaml(depth)}\n")
      write_skill_md("healthy", "---\nname: healthy\n---\nBody.\n")

      names = nil
      stdout, stderr = capture_io { names = registry.list_names }

      refute_includes names, "deep_yml"
      assert_includes names, "healthy"
      assert_match(/skipping skill/, stderr)
      assert_empty stdout
    end
  end

  # The guard must not reject legitimate structure -- nesting right up to
  # the limit still has to load, for both containers.
  def test_a_skill_md_nested_just_under_the_limit_still_loads
    with_tmp_project do
      depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH - 1
      write_skill_md("deep_ok", "---\nname: deep_ok\nx: #{deeply_nested_flow_yaml(depth)}\n---\nBody.\n")

      skill = registry.load("deep_ok")

      refute_nil skill, "nesting right up to the limit must still load"
    end
  end

  def test_a_skill_yml_nested_just_under_the_limit_still_loads
    with_tmp_project do
      depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH - 1
      FileUtils.mkdir_p("config/riggs/skills/deep_yml_ok")
      yaml = "name: deep_yml_ok\nx: #{deeply_nested_flow_yaml(depth)}\n"
      File.write("config/riggs/skills/deep_yml_ok/SKILL.yml", yaml)

      skill = registry.load("deep_yml_ok")

      refute_nil skill, "nesting right up to the limit must still load"
    end
  end

  # `load` returns nil for two unrelated reasons: nobody asked for a skill,
  # and the skill that was asked for could not be read. Enumeration wants the
  # second one soft -- one bad file must not take down `skills:list`. A caller
  # that named a skill on purpose wants it loud, because downstream
  # (ToolLoop#resolve_tools) nil means "this step is unconstrained" and hands
  # over every MCP tool. `load!` is the loud variant; `load` keeps its
  # nil-returning contract for enumeration and for `skills:show`.
  def test_load_bang_raises_when_a_named_skill_cannot_be_parsed
    with_tmp_project do
      write_skill_md("broken", "---\nname: broken\ndesc: [unclosed\n---\nBody.\n")

      err = assert_raises(Riggs::SkillUnavailable) { registry.load!("broken") }

      assert_match(/broken/, err.message, "the error must name the skill the step asked for")
    end
  end

  def test_load_bang_raises_when_a_named_skill_does_not_exist
    with_tmp_project do
      assert_raises(Riggs::SkillUnavailable) { registry.load!("no_such_skill") }
    end
  end

  def test_load_bang_returns_the_skill_when_it_loads
    with_tmp_project do
      write_skill_md("fine", "---\nname: fine\ndescription: Fine.\n---\nBody.\n")

      assert_equal "fine", registry.load!("fine")[:name]
    end
  end

  def test_load_bang_honors_a_version_pin_that_cannot_be_satisfied
    with_tmp_project do
      assert_raises(Riggs::SkillUnavailable) { registry.load!("triage_v1@9.9.9") }
    end
  end

  # `load` must NOT start raising: `skills:show` prints "Skill not found" for a
  # typo, and enumeration tolerates a bad file. Only `load!` is loud.
  def test_load_still_returns_nil_for_an_unloadable_skill
    with_tmp_project do
      write_skill_md("broken", "---\nname: broken\ndesc: [unclosed\n---\nBody.\n")

      assert_nil registry.load("broken")
    end
  end

  # The skip warning is the one line guaranteed to print when a hostile skill
  # file is present, which makes it the worst place to interpolate untrusted
  # text unescaped. The directory name is attacker-controlled wherever the
  # skill file is, and a filename may contain an ESC byte.
  def test_the_skip_warning_strips_terminal_control_sequences
    with_tmp_project do
      dir = "config/riggs/skills/ok\e[2K\rSAFE"
      FileUtils.mkdir_p(dir)
      File.write("#{dir}/SKILL.md", "---\nname: x\nbad: [unclosed\n---\nBody.\n")

      err = capture_io { registry.list }.last

      refute_includes err, "\e", "a skill directory name must not carry an ESC byte to stderr"
      refute_includes err, "\r", "nor a carriage return that would rewrite the warning line"
      assert_includes err, "skipping skill", "the warning itself must still be printed"
    end
  end

  # The other half of the same hole, in a second call site: an unloadable skill
  # made build_system_prompt drop the skill's instructions and keep going, so
  # the step ran with only the generic "You are agent X" preamble. Unscoped
  # tools and missing instructions arrive together, and neither is announced.
  def test_a_step_naming_an_unloadable_skill_does_not_run_without_its_prompt
    with_tmp_project do
      write_skill_md("broken", "---\nname: broken\ndesc: [unclosed\n---\nBe careful.\n")
      workflow = {
        name: "flow", context_window: 32_000, reserve_tokens: 16_384,
        keep_recent_tokens: 20_000, max_llm_calls: 5, timeout_seconds: 60,
        providers: { default: { relay_chain: ["mock"] } },
        steps: [Riggs::Workflow::StepNode.from_hash(
          "id" => "s", "input" => "go", "output_var" => "o", "skill" => "broken"
        )]
      }
      engine = Riggs::Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: { id: "eng_bob", memory_namespace: "eng_bob_private" },
        db_path: "./db/riggs.sqlite3",
        skill_registry: registry
      )

      capture_io do
        assert_raises(Riggs::SkillUnavailable) { engine.execute(StringIO.new, input: {}) }
      end

      assert_equal :failed, engine.status
    end
  end
end

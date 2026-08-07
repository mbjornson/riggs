# frozen_string_literal: true

require_relative "test_helper"

class TestSkillFrontmatter < Minitest::Test
  def test_splits_frontmatter_from_body
    text = "---\nname: writer\ndescription: Writes things\n---\nDo the thing.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "writer", result[:data]["name"]
    assert_equal "Writes things", result[:data]["description"]
    assert_equal "Do the thing.\n", result[:body]
  end

  def test_a_document_without_frontmatter_is_all_body
    text = "# Just markdown\n\nNo header here.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_empty result[:data]
    assert_equal text, result[:body]
  end

  def test_an_empty_frontmatter_block_yields_an_empty_hash
    text = "---\n---\nBody text.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_empty result[:data]
    assert_equal "Body text.\n", result[:body]
  end

  # Markdown uses --- for horizontal rules. Only the FIRST closing delimiter
  # ends the frontmatter; everything after it is body, rules included.
  def test_a_horizontal_rule_in_the_body_stays_in_the_body
    text = "---\nname: writer\n---\nIntro.\n\n---\n\nMore prose.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "writer", result[:data]["name"]
    assert_includes result[:body], "---"
    assert_includes result[:body], "More prose."
  end

  # A document that opens a block and never closes it is far more likely to be
  # prose starting with a horizontal rule than a truncated header.
  def test_an_unterminated_opening_delimiter_is_treated_as_no_frontmatter
    text = "---\nthis never closes\nand keeps going\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_empty result[:data]
    assert_equal text, result[:body]
  end

  # These files come from other people's repositories.
  def test_crlf_input_parses_identically_to_lf
    crlf = "---\r\nname: writer\r\n---\r\nDo the thing.\r\n"

    result = Riggs::SkillFrontmatter.parse(crlf)

    assert_equal "writer", result[:data]["name"]
    assert_equal "Do the thing.\n", result[:body]
  end

  def test_a_leading_byte_order_mark_does_not_defeat_delimiter_detection
    text = "﻿---\nname: writer\n---\nBody.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "writer", result[:data]["name"]
    assert_equal "Body.\n", result[:body]
  end

  def test_non_mapping_frontmatter_raises
    text = "---\n- one\n- two\n---\nBody.\n"

    assert_raises(ArgumentError) { Riggs::SkillFrontmatter.parse(text) }
  end

  def test_malformed_yaml_raises_psych_syntax_error
    text = "---\nname: [unclosed\n---\nBody.\n"

    assert_raises(Psych::SyntaxError) { Riggs::SkillFrontmatter.parse(text) }
  end

  # An off-the-shelf skill file is ordinary content, not an attack: an
  # unquoted date-shaped scalar is auto-typed by Psych and must load as a
  # Date, not be rejected as a disallowed class.
  def test_a_date_valued_frontmatter_key_parses_without_raising
    text = "---\nname: dated\nupdated: 2026-08-05\n---\nBody.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "dated", result[:data]["name"]
    assert_equal Date.new(2026, 8, 5), result[:data]["updated"]
  end

  # Skill files have no legitimate need for YAML anchors; aliases are
  # disabled outright rather than merely constrained.
  def test_an_alias_reference_raises_aliases_not_enabled
    text = "---\nname: aliased\ntags: &t [a, b]\nmore: *t\n---\nBody.\n"

    assert_raises(Psych::AliasesNotEnabled) { Riggs::SkillFrontmatter.parse(text) }
  end

  # SystemStackError descends from Exception, not StandardError, so it would
  # escape SkillRegistry#read_skill_dir's rescue outright and take every
  # skill in the registry down with it. The guard must reject over-deep
  # flow-style nesting itself, before Psych ever sees it, so the failure
  # here stays an ordinary, catch-and-skip ArgumentError.
  def test_deeply_nested_flow_style_frontmatter_raises_argument_error_not_system_stack_error
    depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH + 1
    nested = ("[" * depth) + ("]" * depth)
    text = "---\nname: deep\nx: #{nested}\n---\nBody.\n"

    error = assert_raises(ArgumentError) { Riggs::SkillFrontmatter.parse(text) }
    assert_match(/nest/i, error.message)
  end

  # The guard must reject only genuinely excessive nesting -- built from the
  # constant itself so this stays correct if the limit is ever retuned.
  def test_flow_style_nesting_just_under_the_limit_still_loads
    depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH - 1
    nested = ("[" * depth) + ("]" * depth)
    text = "---\nname: deep\nx: #{nested}\n---\nBody.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "deep", result[:data]["name"]
  end

  # Block style has no closing token, so nesting depth grows with
  # indentation instead of brackets. Confirmed empirically to also overflow
  # Psych's stack (around ~1,500 levels at 2-space indent), so it needs the
  # same guard.
  def test_deeply_indented_block_style_frontmatter_raises_argument_error
    depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH + 1
    text = "---\n#{deeply_indented_yaml(depth)}---\nBody.\n"

    assert_raises(ArgumentError) { Riggs::SkillFrontmatter.parse(text) }
  end

  # block_depth measures raw indentation columns, not levels, so it is a
  # deliberate over-estimate: at 2 spaces per level, this document's deepest
  # column count is (depth * 2), which must stay at or under the limit for
  # this to prove the guard admits legitimate structure.
  def test_block_style_nesting_just_under_the_limit_still_loads
    depth = (Riggs::SkillFrontmatter::MAX_NESTING_DEPTH / 2) - 1
    text = "---\n#{deeply_indented_yaml(depth)}---\nBody.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    refute_empty result[:data]
  end

  # A chain of "- " sequence markers on a single line (YAML's compact
  # nested-sequence form) grows depth without ever indenting, so the
  # indentation proxy alone would miss it. Confirmed empirically to also
  # overflow Psych's stack around ~1,500 levels.
  def test_deeply_chained_compact_sequence_frontmatter_raises_argument_error
    depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH + 1
    text = "---\nname: deep\nx:\n  #{'- ' * depth}1\n---\nBody.\n"

    assert_raises(ArgumentError) { Riggs::SkillFrontmatter.parse(text) }
  end

  # A "---" document marker or a "----" markdown divider pasted into a
  # description must not be mistaken for a chain of sequence markers.
  def test_a_run_of_bare_dashes_does_not_trip_the_sequence_chain_guard
    depth = Riggs::SkillFrontmatter::MAX_NESTING_DEPTH + 1
    text = "---\nname: deep\ndescription: |\n  #{'-' * depth}\n---\nBody.\n"

    result = Riggs::SkillFrontmatter.parse(text)

    assert_equal "deep", result[:data]["name"]
  end

  # The consolidated loader labels its error with whichever container called
  # it. Pinned exactly, byte for byte, since SkillRegistry relies on this
  # message staying stable.
  def test_load_mapping_reports_the_given_source_in_its_error_message
    error = assert_raises(ArgumentError) do
      Riggs::SkillFrontmatter.load_mapping("- one\n- two\n", source: "SKILL.yml")
    end

    assert_equal "SKILL.yml must be a mapping, got Array", error.message
  end

  # Same guarantee via the SKILL.md frontmatter path, which routes through
  # #parse rather than calling #load_mapping directly.
  def test_frontmatter_non_mapping_error_message_is_unchanged
    text = "---\n- one\n- two\n---\nBody.\n"

    error = assert_raises(ArgumentError) { Riggs::SkillFrontmatter.parse(text) }

    assert_equal "SKILL.md frontmatter must be a mapping, got Array", error.message
  end

  def deeply_indented_yaml(depth)
    lines = (0...depth).map { |i| "#{'  ' * i}a:" }
    lines << "#{'  ' * depth}leaf: 1"
    "#{lines.join("\n")}\n"
  end
end

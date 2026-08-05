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
end

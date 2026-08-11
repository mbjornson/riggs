# frozen_string_literal: true

require "test_helper"
require "json"

class TestMCPClient < Minitest::Test
  def test_manager_from_empty
    mgr = Riggs::MCP::Manager.from_config({}, provenance: {})
    assert_empty mgr.server_names
    assert_empty mgr.list_tools
  end
end

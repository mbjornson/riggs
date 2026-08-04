# frozen_string_literal: true

require "thor"
require "psych"
require "fileutils"
require "json"

module Riggs
  class Error < StandardError; end
end

require_relative "riggs/version"
require_relative "riggs/identity"
require_relative "riggs/config_store"
require_relative "riggs/storage"
require_relative "riggs/usage"
require_relative "riggs/model_info"
require_relative "riggs/events"
require_relative "riggs/memory/service"
require_relative "riggs/workflow/loader"
require_relative "riggs/workflow/graph_engine"
require_relative "riggs/providers/router"
require_relative "riggs/skills/registry"
require_relative "riggs/mcp/client"
require_relative "riggs/mcp/manager"
require_relative "riggs/triggers"
require_relative "riggs/web/app"
require_relative "riggs/cli/commands"

begin
  require_relative "riggs/engine"
rescue LoadError
  # Rails engine is optional
end

module Riggs
  def self.run(args = ARGV)
    CLI.start(args)
  end
end

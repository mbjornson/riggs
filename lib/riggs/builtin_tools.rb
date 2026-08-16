# frozen_string_literal: true

module Riggs
  # Local tools implemented inside Riggs (not MCP). ToolLoop consults this
  # registry before the MCP manager so core does not special-case names.
  module BuiltinTools
    HANDLERS = {
      "lookup_runbook" => lambda { |args|
        topic = args[:topic] || args["topic"] || "general"
        "Runbook[#{topic}]: Check credentials, rotate tokens, verify upstream health."
      }
    }.freeze

    def self.names
      HANDLERS.keys
    end

    def self.builtin?(name)
      HANDLERS.key?(name.to_s)
    end

    # Returns the tool output String, or nil when the name is not a builtin.
    def self.call(name, arguments = {})
      handler = HANDLERS[name.to_s]
      return nil unless handler

      handler.call(arguments || {})
    end
  end
end

# frozen_string_literal: true

require "json"
require "securerandom"

module Riggs
  module Providers
    class Error < Riggs::Error; end
    class RateLimitError < Error; end
    class TimeoutError < Error; end

    # The CLI ran but is not authenticated. A subclass of Error on purpose:
    # Router relays to the next provider on Error, and a provider that is not
    # logged in should fail over exactly like any other failure.
    class AuthError < Error; end

    class Base
      attr_reader :name, :options

      def initialize(name:, options: {})
        @name = name.to_s
        @options = options || {}
      end

      # Returns { provider:, model:, content:, tool_calls: [], usage:, raw: }
      def complete(messages:, system: nil, timeout: 60, tools: nil)
        raise NotImplementedError, "#{self.class}#complete must be implemented"
      end

      protected

      def parse_tool_line(content)
        return [] unless content.to_s.start_with?("TOOL:")

        line = content.to_s.sub(/\ATOOL:/, "")
        tname, raw_args = line.split("|", 2)
        args = raw_args && !raw_args.empty? ? JSON.parse(raw_args) : {}
        [{ id: "tool_#{SecureRandom.hex(4)}", name: tname.strip, arguments: args }]
      rescue JSON::ParserError
        [{ id: "tool_#{SecureRandom.hex(4)}", name: tname.to_s.strip, arguments: {} }]
      end
    end
  end
end

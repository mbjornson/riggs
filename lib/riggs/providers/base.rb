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
      AUTH_MODES = %w[api].freeze
      DEFAULT_AUTH_MODE = "api"

      def self.auth_modes = self::AUTH_MODES
      def self.default_auth_mode = self::DEFAULT_AUTH_MODE

      def self.resolve_auth_mode(value, provider:)
        mode = value.to_s.strip.downcase
        return default_auth_mode if mode.empty?
        return mode if auth_modes.include?(mode)

        raise Error, "provider '#{provider}': auth mode #{value.inspect} is not " \
                     "supported by #{name} (expected one of: #{auth_modes.join(', ')})"
      end

      attr_reader :name, :options

      def initialize(name:, options: {})
        @name = name.to_s
        @options = options || {}
      end

      def auth_mode = self.class.resolve_auth_mode(options[:auth], provider: name)

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

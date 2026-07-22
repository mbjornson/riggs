# frozen_string_literal: true

module Riggs
  module Providers
    class Error < Riggs::Error; end
    class RateLimitError < Error; end
    class TimeoutError < Error; end

    class Base
      attr_reader :name, :options

      def initialize(name:, options: {})
        @name = name.to_s
        @options = options || {}
      end

      def complete(messages:, system: nil, timeout: 60)
        raise NotImplementedError, "#{self.class}#complete must be implemented"
      end
    end
  end
end

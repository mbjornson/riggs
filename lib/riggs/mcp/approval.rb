# frozen_string_literal: true

module Riggs
  module MCP
    class NotApproved < Error; end

    # Rendering a command for a human to approve is a leak path: a secret
    # passed in argv would land in the terminal and in scrollback. This
    # redacts the common shape -- a value following a secret-bearing flag, in
    # either `--flag value` or `--flag=value` form. It is a heuristic and
    # cannot catch a bare positional secret; MCP configs are documented to
    # pass secrets by environment variable name instead.
    class Approval
      SECRET_FLAG = /\A--?[\w-]*(key|token|secret|password|credential)[\w-]*\z/i
      SECRET_INLINE = /\A(--?[\w-]*(key|token|secret|password|credential)[\w-]*)=(.+)\z/i
      REDACTED = "[redacted]"

      def self.redact(command, args)
        Redactor.new(command, args).text
      end

      class Redactor
        def initialize(command, args)
          @command = command.to_s
          @args = Array(args).map(&:to_s)
        end

        def text
          ([@command] + redacted_arguments).join(" ")
        end

        private

        def redacted_arguments
          @args.reduce([[], false]) { |state, arg| redact(state, arg) }.first
        end

        def redact(state, argument)
          return [state.first + [REDACTED], false] if state.last
          return [state.first + [inline(argument)], false] if inline?(argument)

          [state.first + [argument], secret_flag?(argument)]
        end

        def inline?(argument)
          !SECRET_INLINE.match(argument).nil?
        end

        def inline(argument)
          "#{SECRET_INLINE.match(argument)[1]}=#{REDACTED}"
        end

        def secret_flag?(argument)
          SECRET_FLAG.match?(argument)
        end
      end
    end
  end
end

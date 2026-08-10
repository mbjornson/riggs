# frozen_string_literal: true

require "digest"
require "json"

module Riggs
  class Trust
    # The identity of an approved MCP server: what will run, with which
    # arguments, forwarding which environment variable NAMES.
    #
    # D1 -- names are part of that identity, so renaming a forwarded variable
    # re-prompts. Excluding them would let an approved server be pointed at a
    # different secret with no re-approval, which is the worse failure.
    #
    # Values never participate. A digest is one-way, but the rule "no value
    # enters this subsystem" is checkable and "no value escapes this hash" is
    # not.
    class Digest
      def self.of(command:, args:, env:)
        new(command: command, args: args, env: env).value
      end

      def initialize(command:, args:, env:)
        @command = command
        @args = Array(args).map(&:to_s)
        @env = env || {}
      end

      # ::Digest, not Digest -- inside this class the bare constant resolves to
      # this class itself, not to the stdlib.
      def value
        "sha256:#{::Digest::SHA256.hexdigest(canonical)}"
      end

      private

      def canonical
        JSON.generate("command" => resolved, "args" => @args, "env_keys" => env_keys)
      end

      # The RESOLVED executable, not the configured name -- see Executable.
      def resolved
        Executable.resolve(command: @command, env: @env)
      end

      # Sorted, so the order variables happen to be declared in does not change
      # a server's identity.
      def env_keys
        @env.keys.map(&:to_s).sort
      end
    end
  end
end

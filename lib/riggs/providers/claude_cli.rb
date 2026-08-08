# frozen_string_literal: true

require_relative "cli"

module Riggs
  module Providers
    # Claude Code CLI: `claude -p PROMPT --bare`
    class ClaudeCli < Cli
      protected

      def default_command
        "claude"
      end

      def child_env
        env = {}
        # A subscription credential in its own right -- the documented path for
        # non-interactive use -- so it survives both modes.
        token = ENV.fetch("CLAUDE_CODE_OAUTH_TOKEN", nil)
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token if token && !token.empty?

        if auth_mode == "subscription"
          # nil unsets it in the child. ANTHROPIC_API_KEY otherwise OVERRIDES a
          # Pro/Max subscription (code.claude.com/docs/en/env-vars), so an
          # exported key would silently bill the API account on every step.
          env["ANTHROPIC_API_KEY"] = nil
        else
          key = ENV.fetch("ANTHROPIC_API_KEY", nil)
          env["ANTHROPIC_API_KEY"] = key if key && !key.empty?
        end
        env
      end

      def argv_for(prompt)
        args = ["-p", prompt, "--bare"]
        model = options[:model]
        args += ["--model", model.to_s] if model && !model.to_s.empty?
        system_prompt = options[:system_prompt]
        args += ["--system-prompt", system_prompt.to_s] if system_prompt && !system_prompt.to_s.empty?
        args
      end
    end
  end
end

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

      def ensure_auth!
        require_env!("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
      end

      def child_env
        {
          "ANTHROPIC_API_KEY" => ENV.fetch("ANTHROPIC_API_KEY", nil),
          "CLAUDE_CODE_OAUTH_TOKEN" => ENV.fetch("CLAUDE_CODE_OAUTH_TOKEN", nil)
        }.compact
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

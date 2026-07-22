# frozen_string_literal: true

require_relative "cli"

module Riggs
  module Providers
    # OpenAI Codex CLI: `codex exec PROMPT`
    class CodexCli < Cli
      protected

      def default_command
        "codex"
      end

      def ensure_auth!
        require_env!("CODEX_API_KEY", "OPENAI_API_KEY")
      end

      def child_env
        key = ENV.fetch("CODEX_API_KEY", nil)
        key = ENV.fetch("OPENAI_API_KEY", nil) if key.nil? || key.empty?
        { "CODEX_API_KEY" => key }.compact
      end

      def argv_for(prompt)
        args = ["exec", prompt]
        model = options[:model]
        args += ["--model", model.to_s] if model && !model.to_s.empty?
        args
      end
    end
  end
end

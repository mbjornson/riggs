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

      def child_env
        # Codex prefers its stored ChatGPT auth over an env key today, so this
        # is belt-and-braces -- but a precedence rule inside someone else's CLI
        # is not something Riggs should depend on staying put.
        return { "CODEX_API_KEY" => nil, "OPENAI_API_KEY" => nil } if auth_mode == "subscription"

        key = ENV.fetch("CODEX_API_KEY", nil)
        key = ENV.fetch("OPENAI_API_KEY", nil) if key.nil? || key.empty?
        key.nil? || key.empty? ? {} : { "CODEX_API_KEY" => key }
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

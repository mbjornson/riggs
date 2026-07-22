# frozen_string_literal: true

require_relative "cli"

module Riggs
  module Providers
    # Cursor CLI: `agent -p PROMPT --output-format text`
    class CursorCli < Cli
      protected

      def default_command
        "agent"
      end

      def ensure_auth!
        require_env!("CURSOR_API_KEY")
      end

      def child_env
        { "CURSOR_API_KEY" => ENV["CURSOR_API_KEY"] }.compact
      end

      def argv_for(prompt)
        args = ["-p", prompt, "--output-format", "text"]
        model = options[:model]
        args += ["--model", model.to_s] if model && !model.to_s.empty?
        api_key = options[:api_key]
        args = ["--api-key", api_key.to_s] + args if api_key && !api_key.to_s.empty?
        args
      end
    end
  end
end

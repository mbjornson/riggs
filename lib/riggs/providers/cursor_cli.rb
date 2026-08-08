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

      def child_env
        return { "CURSOR_API_KEY" => nil } if auth_mode == "subscription"

        key = ENV.fetch("CURSOR_API_KEY", nil)
        key.nil? || key.empty? ? {} : { "CURSOR_API_KEY" => key }
      end

      def argv_for(prompt)
        args = ["-p", prompt, "--output-format", "text"]
        model = options[:model]
        args += ["--model", model.to_s] if model && !model.to_s.empty?
        # An argv flag would route the key past the env scrub entirely.
        return args if auth_mode == "subscription"

        api_key = options[:api_key]
        args = ["--api-key", api_key.to_s] + args if api_key && !api_key.to_s.empty?
        args
      end
    end
  end
end

# frozen_string_literal: true

require_relative "base"
require_relative "cli_runner"

module Riggs
  module Providers
    # Base for providers that shell out to a local agent CLI.
    class Cli < Base
      def complete(messages:, system: nil, timeout: 60, tools: nil)
        ensure_auth!
        prompt = build_prompt(messages: messages, system: system)
        command = options[:command] || default_command
        args = argv_for(prompt)
        env = child_env

        result = runner.run(
          command: command,
          args: args,
          env: env,
          timeout: timeout
        )
        content = parse_stdout(result.stdout)
        tool_calls = parse_tool_line(content)
        {
          provider: name,
          model: options[:model],
          content: content,
          tool_calls: tool_calls,
          usage: {},
          raw: { stdout: result.stdout, stderr: result.stderr }
        }
      end

      protected

      def default_command
        raise NotImplementedError
      end

      def argv_for(_prompt)
        raise NotImplementedError
      end

      def parse_stdout(stdout)
        stdout.to_s.strip
      end

      def ensure_auth!
        # optional override
      end

      def child_env
        {}
      end

      def runner
        options[:runner] || CliRunner
      end

      def build_prompt(messages:, system:)
        parts = []
        parts << "System:\n#{system}" if system && !system.to_s.empty?
        Array(messages).each do |m|
          role = m[:role] || m["role"]
          content = m[:content] || m["content"]
          parts << "#{role.to_s.capitalize}:\n#{content}"
        end
        parts.join("\n\n")
      end

      def require_env!(*keys)
        present = keys.find { |k| ENV.fetch(k, nil) && !ENV[k].empty? }
        return present if present

        raise Error, "#{name} requires one of: #{keys.join(', ')}"
      end
    end
  end
end

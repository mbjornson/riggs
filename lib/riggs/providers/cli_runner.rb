# frozen_string_literal: true

require "open3"
require "timeout"
require_relative "base"

module Riggs
  module Providers
    module CliRunner
      module_function

      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def run(command:, args: [], env: {}, timeout: 60, stdin_data: nil)
        raise Error, "CLI command is blank" if command.nil? || command.to_s.strip.empty?

        binary = resolve_binary(command)
        raise Error, "CLI binary not found on PATH: #{command}" unless binary

        full_env = ENV.to_h.merge(env.transform_keys(&:to_s))
        argv = [binary, *Array(args).map(&:to_s)]

        stdout = stderr = ""
        status = nil

        begin
          Timeout.timeout(timeout.to_f) do
            stdout, stderr, status = Open3.capture3(full_env, *argv, stdin_data: stdin_data.to_s)
          end
        rescue Timeout::Error
          raise TimeoutError, "CLI timed out after #{timeout}s: #{argv.join(' ')}"
        end

        result = Result.new(stdout: stdout.to_s, stderr: stderr.to_s, status: status)
        raise_for_failure!(result, argv)
        result
      end

      def which(command)
        resolve_binary(command)
      end

      def resolve_binary(command)
        cmd = command.to_s
        return cmd if cmd.include?(File::SEPARATOR) && File.executable?(cmd)

        exts = ENV["PATHEXT"] ? ENV["PATHEXT"].split(";") : [""]
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          exts.each do |ext|
            candidate = File.join(dir, "#{cmd}#{ext}")
            return candidate if File.executable?(candidate)
          end
        end
        nil
      end

      def raise_for_failure!(result, argv)
        return if result.status&.success?

        combined = "#{result.stderr}\n#{result.stdout}"
        if combined.match?(/rate.?limit|429|too many requests/i)
          raise RateLimitError, "CLI rate limited: #{argv.first}: #{result.stderr[0, 200]}"
        end

        code = result.status&.exitstatus || "unknown"
        raise Error, "CLI failed (exit #{code}): #{argv.join(' ')}\n#{result.stderr[0, 400]}"
      end
      private_class_method :raise_for_failure!
    end
  end
end

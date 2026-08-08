# frozen_string_literal: true

require "open3"
require_relative "base"

module Riggs
  module Providers
    module CliRunner
      module_function

      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      AUTH_FAILURE = /not logged in|unauthorized|401|authentication|please (run )?login|no credentials/i

      def run(command:, args: [], env: {}, timeout: 60, stdin_data: nil)
        raise Error, "CLI command is blank" if command.nil? || command.to_s.strip.empty?

        binary = resolve_binary(command)
        raise Error, "CLI binary not found on PATH: #{command}" unless binary

        full_env = ENV.to_h.merge(env.transform_keys(&:to_s))
        argv = [binary, *Array(args).map(&:to_s)]

        stdin, stdout, stderr, wait_thr = Open3.popen3(full_env, *argv)
        begin
          begin
            stdin.write(stdin_data.to_s)
            stdin.close
          rescue Errno::EPIPE
            nil # child exited without reading stdin
          end
          out_reader = Thread.new { stdout.read }
          err_reader = Thread.new { stderr.read }

          if wait_thr.join(timeout.to_f).nil?
            begin
              Process.kill("KILL", wait_thr.pid)
            rescue Errno::ESRCH
              nil
            end
            wait_thr.value # reap
            raise TimeoutError, "CLI timed out after #{timeout}s: #{argv.join(' ')}"
          end

          result = Result.new(stdout: out_reader.value.to_s, stderr: err_reader.value.to_s, status: wait_thr.value)
          raise_for_failure!(result, argv)
          result
        ensure
          [stdin, stdout, stderr].each do |io|
            io.close unless io.closed?
          rescue StandardError
            nil
          end
        end
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

        raise AuthError, "CLI not authenticated: #{argv.first}: #{result.stderr[0, 200]}" if combined.match?(AUTH_FAILURE)

        code = result.status&.exitstatus || "unknown"
        raise Error, "CLI failed (exit #{code}): #{argv.join(' ')}\n#{result.stderr[0, 400]}"
      end
      private_class_method :raise_for_failure!
    end
  end
end

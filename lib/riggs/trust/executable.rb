# frozen_string_literal: true

module Riggs
  class Trust
    # Turns a configured command into the absolute path that will actually be
    # spawned. A digest over the literal string "mcp" binds nothing: a later
    # PATH change selects a different binary under the same name and the old
    # approval still matches. Resolving here, and re-resolving at spawn, means
    # a different binary is a different digest.
    #
    # It also keeps PATH itself out of the digest input, which recording PATH
    # as an environment value would not.
    class Executable
      # POSIX: an EMPTY PATH component means the current directory, so
      # PATH=":/usr/bin" can run ./mcp. File.join("", cmd) yields "/cmd" --
      # a file in the filesystem root, not the one that runs.
      CURRENT_DIRECTORY = "."

      # Where exec looks when PATH is unset in the child.
      DEFAULT_PATH = "/bin:/usr/bin"

      def self.resolve(command:, env:)
        new(command: command, env: env).path
      end

      def initialize(command:, env:)
        @command = command.to_s
        @env = mapping(env)
      end

      # An unresolvable name resolves to "unresolved:<name>" so approval still
      # binds something stable and the spawn fails on its own terms, not here.
      def path
        return unresolved unless resolvable?
        return realpath(File.expand_path(@command)) if qualified?

        found = candidates.detect { |candidate| runnable?(candidate) }
        return unresolved if found.nil?

        realpath(found)
      end

      private

      # No filename may contain a NUL byte, and File.expand_path raises
      # ArgumentError on one -- which escaped as a raw crash from inside
      # digest computation, where a malformed MCP declaration should have
      # produced a stable digest instead. An empty command is not a filename
      # either, and would otherwise resolve against each PATH entry as a
      # directory.
      def resolvable?
        !@command.empty? && !@command.include?("\u0000")
      end

      def unresolved
        "unresolved:#{@command}"
      end

      # A declaration whose env is not a mapping forwards no variables. Calling
      # .transform_keys on it crashed the digest instead of digesting it.
      def mapping(env)
        return env.transform_keys(&:to_s) if env.is_a?(Hash)

        {}
      end

      def qualified?
        @command.include?(File::SEPARATOR)
      end

      def candidates
        search_path.lazy.map { |dir| expand(dir) }
      end

      def expand(dir)
        File.expand_path(File.join(base_for(dir), @command))
      end

      # Not `dir` on its own: File.join("", cmd) is "/cmd", which would digest
      # a file in the filesystem root while the child executes one in the
      # working directory.
      def base_for(dir)
        return CURRENT_DIRECTORY if dir.empty?

        dir
      end

      def runnable?(candidate)
        File.file?(candidate) && File.executable?(candidate)
      end

      def search_path
        raw_path.split(File::PATH_SEPARATOR, -1)
      end

      # A key present with a NIL value means "unset in the child" to Open3, and
      # exec then falls back to a system default path rather than to ours. That
      # is why this checks for the key first and the value second, instead of
      # the shorter `@env["PATH"] || ENV["PATH"]`, which cannot tell the two
      # cases apart.
      def raw_path
        return @env["PATH"] || DEFAULT_PATH if @env.key?("PATH")

        ENV.fetch("PATH", DEFAULT_PATH)
      end

      # The winner is realpath'd so a swapped symlink is a different path, and
      # therefore a different approval.
      def realpath(candidate)
        File.realpath(candidate)
      rescue SystemCallError
        candidate
      end
    end
  end
end

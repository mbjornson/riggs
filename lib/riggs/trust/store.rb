# frozen_string_literal: true

require "psych"
require "fileutils"

module Riggs
  class Trust
    # The YAML file behind the registry. Machine-written: riggs rewrites it on
    # every approval, which is why it is a separate file from the
    # hand-authored ~/.riggs/config.yml.
    class Store
      attr_reader :path

      def initialize(path:)
        @path = path
      end

      def read
        return empty unless File.exist?(@path)

        loaded || empty
      end

      def write(data)
        FileUtils.mkdir_p(File.dirname(@path))
        create_private
        File.write(@path, Psych.dump(data))
        @path
      end

      private

      # A fresh nested hash every call, deliberately NOT a shared frozen
      # constant. `{"projects" => {}}.freeze` freezes only the OUTER hash, so
      # every `.dup` of it shares the same inner projects hash -- which the
      # registry then mutates in place, leaking one instance's grants into
      # every other.
      def empty
        { "projects" => {} }
      end

      # Neither symbols nor aliases have any business in a machine-written
      # registry, so this is the strict form rather than the permissive one
      # Identity uses for hand-authored config.
      def loaded
        Psych.safe_load(File.read(@path), permitted_classes: [], aliases: false)
      end

      # Two lines, both load-bearing. File::CREAT with 0o600 creates a NEW file
      # private, but does nothing to the mode of one that already exists, so
      # the chmod tightens a file that arrived world-readable by some other
      # route. Writing content first and chmod'ing after -- the obvious
      # ordering -- leaves a window in which the file is world-readable with
      # the operator's project list already in it.
      def create_private
        File.open(@path, File::WRONLY | File::CREAT, 0o600) { nil }
        File.chmod(0o600, @path)
      end
    end
  end
end

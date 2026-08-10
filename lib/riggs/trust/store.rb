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

      # Opened once, with TRUNC, and written through that one descriptor.
      # NOFOLLOW is what stops the registry becoming a write primitive aimed
      # somewhere else: pointing trust.yml at another file made riggs write
      # its project list THROUGH the link into that file and chmod the target
      # to 0600.
      WRITE_FLAGS = File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW

      def read
        return empty unless File.exist?(@path)

        shaped(loaded)
      end

      def write(data)
        FileUtils.mkdir_p(File.dirname(@path))
        write_private(Psych.dump(data))
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

      # Order is load-bearing. TRUNC empties a pre-existing file before the
      # chmod, and the chmod lands before any content is written, so at no
      # point does a readable-by-others file hold the operator's project list.
      # The 0o600 on open covers creation; File#chmod covers a file that
      # already existed 0644, which the creation mode does not touch.
      def write_private(body)
        File.open(@path, WRITE_FLAGS, 0o600) do |file|
          file.chmod(0o600)
          file.write(body)
        end
      rescue Errno::ELOOP, Errno::EMLINK
        raise Error, "#{@path} is a symbolic link; riggs will not write trust records through one"
      end

      # trust.yml is the one file riggs writes itself, so it is the one most
      # likely to be found half-written after a crash or a full disk. A
      # document that is not the shape riggs writes is treated as absent
      # rather than propagated: `data["projects"] ||= {}` raises IndexError on
      # a String and TypeError on a list, from inside `trusted?` -- which
      # every riggs command calls, so one corrupt file made the whole tool
      # unusable with an opaque stack trace.
      def shaped(data)
        return empty if data.nil?
        return data if shape_ok?(data)

        warn("riggs: #{@path} is not in the format riggs writes; ignoring it")
        empty
      end

      def shape_ok?(data)
        return false unless data.is_a?(Hash)

        entries_ok?(data["projects"])
      end

      # Checked one level deeper than the document: a per-project entry that
      # is not a mapping reaches `entry(...)&.fetch` and raises there instead.
      def entries_ok?(projects)
        return true if projects.nil?

        projects.is_a?(Hash) && projects.each_value.all?(Hash)
      end
    end
  end
end

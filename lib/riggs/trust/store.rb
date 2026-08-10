# frozen_string_literal: true

require "psych"
require "fileutils"
require "securerandom"

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

      # EXCL, not TRUNC. NOFOLLOW stops the registry becoming a write primitive
      # aimed somewhere else through a SYMBOLIC link, but a hard link is not a
      # link to open -- the entry IS the file, and TRUNC wrote our project list
      # into whatever inode was already sitting there and chmod'd it to 0600.
      # EXCL refuses any pre-existing entry at all, link or not, which is the
      # only form of that check that does not have to enumerate link types.
      WRITE_FLAGS = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW

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

      # Written to a fresh private file and renamed over our directory entry.
      # Truncating the existing inode in place was wrong twice over: O_NOFOLLOW
      # stops a SYMBOLIC link but says nothing about a HARD one, where the
      # entry IS the file, so the write landed in a shared inode and chmod'd
      # it to 0600. Renaming replaces our name only and leaves every other
      # name for that inode untouched. It is also atomic, so a crash mid-write
      # cannot leave the half-written file #shaped exists to survive.
      def write_private(body)
        reject_symlink!
        temp = temp_path
        File.open(temp, WRITE_FLAGS, 0o600) { |file| write_body(file, body) }
        File.rename(temp, @path)
      end

      # Random, not "#{@path}.#{Process.pid}.tmp". A pid is public and reused,
      # so the old name told an attacker exactly which entry to occupy before
      # riggs got there, and told two concurrent runs to fight over one file.
      # EXCL above is what refuses an occupied name; this is what stops the
      # name being worth occupying.
      def temp_path
        "#{@path}.#{SecureRandom.hex(8)}.tmp"
      end

      # The rename above already refuses to write THROUGH a link, so this is
      # about telling the operator rather than about safety: someone who
      # deliberately symlinked trust.yml into a dotfiles repo should hear that
      # riggs will not honour it, not silently find it replaced.
      def reject_symlink!
        return unless File.symlink?(@path)

        raise Error, "#{@path} is a symbolic link; riggs will not write trust records through one"
      end

      # chmod before any content: 0o600 on open covers a file we create, and
      # File#chmod covers one that already existed 0644, which the creation
      # mode does not touch.
      def write_body(file, body)
        file.chmod(0o600)
        file.write(body)
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

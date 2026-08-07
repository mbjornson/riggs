# frozen_string_literal: true

require "thor"
require "psych"
require "fileutils"
require "json"

module Riggs
  class Error < StandardError; end

  # Text that came out of a file Riggs did not author, on its way to a
  # terminal. Psych rejects a raw ESC byte, but YAML's double-quoted style
  # decodes its own "\e" escape into one, a SKILL.md body is not YAML at all,
  # and a directory name can hold any byte the filesystem allows. The damage is
  # not garbled output: "\e[2K\r" erases the line and returns the cursor to
  # column 0, so the real text is replaced by whatever the file wanted the
  # operator to read.
  #
  # \p{Cc} is C0, DEL, and C1 -- every control character. Tab and newline are
  # subtracted because a skill body is markdown and needs its line structure.
  # scrub first: a file holding invalid UTF-8 would otherwise raise here.
  TERMINAL_CONTROL = /[\p{Cc}&&[^\n\t]]/

  def self.sanitize_for_terminal(text)
    text.to_s.scrub("").gsub(TERMINAL_CONTROL, "")
  end
end

require_relative "riggs/version"
require_relative "riggs/identity"
require_relative "riggs/config_store"
require_relative "riggs/storage"
require_relative "riggs/usage"
require_relative "riggs/model_info"
require_relative "riggs/events"
require_relative "riggs/memory/service"
require_relative "riggs/workflow/loader"
require_relative "riggs/workflow/graph_engine"
require_relative "riggs/providers/router"
require_relative "riggs/skills/registry"
require_relative "riggs/mcp/client"
require_relative "riggs/mcp/manager"
require_relative "riggs/triggers"
require_relative "riggs/web/app"
require_relative "riggs/cli/commands"

begin
  require_relative "riggs/engine"
rescue LoadError
  # Rails engine is optional
end

module Riggs
  def self.run(args = ARGV)
    CLI.start(args)
  end
end

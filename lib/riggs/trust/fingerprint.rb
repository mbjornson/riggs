# frozen_string_literal: true

require "digest"

module Riggs
  class Trust
    # The bytes of the project config the operator reviewed. Trusting a PATH
    # answers "may this project speak at all"; the fingerprint answers "is this
    # the file they read when they said yes". Without it, a trusted repository
    # could rewrite its own .riggs/config.yml -- users, roles, MCP servers --
    # and be believed on the strength of an answer given about other bytes.
    class Fingerprint
      def self.of(config_path)
        return nil unless config_path && File.exist?(config_path)

        ::Digest::SHA256.hexdigest(File.binread(config_path))
      end

      def self.record(config_path)
        { "path" => File.expand_path(config_path), "fingerprint" => of(config_path) }
      end

      # Compared as a whole record: a fingerprint that matches while the path
      # does not means the grant was made about a different file.
      #
      # The nil guard is the whole point of the first line, not defensive
      # noise: `of` returns nil for a file that is not there, so a record
      # written while the config was missing compared nil == nil and answered
      # "this is the file you trusted" about a file that does not exist.
      def self.matches?(record, config_path)
        return false unless record.is_a?(Hash)

        current = of(config_path)
        return false if current.nil?

        record["fingerprint"] == current && record["path"] == File.expand_path(config_path)
      end
    end
  end
end

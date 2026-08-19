# frozen_string_literal: true

require "json"

module Riggs
  class Trust
    class Legacy
      MARKER = "legacy_project_trust_imported"

      def initialize(trust:)
        @trust = trust
      end

      def import
        return if imported? || entries.nil?

        entries.each { |project_path, entry| import_entry(project_path, entry) }
        mark_imported!
      end

      private

      def imported?
        store.read[MARKER] == true
      end

      def entries
        parsed = JSON.parse(File.read(legacy_path))
        parsed if parsed.is_a?(Hash)
      rescue StandardError
        nil
      end

      def import_entry(project_path, entry)
        return unless entry.is_a?(Hash) && entry["config_path"].is_a?(String)

        @trust.grant!(project_path)
        @trust.record_config!(project_path, entry["config_path"])
      end

      def mark_imported!
        data = store.read
        data[MARKER] = true
        store.write(data)
      end

      def store
        @store ||= Store.new(path: @trust.path)
      end

      def legacy_path
        File.join(legacy_home, "trusted_projects.json")
      end

      def legacy_home
        ENV["RIGGS_TRUST_HOME"] || Trust.home
      end
    end
  end
end

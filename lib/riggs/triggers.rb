# frozen_string_literal: true

module Riggs
  module Triggers
    def self.match(workflow, text:)
      triggers = Array(workflow[:triggers])
      return true if triggers.empty? || triggers.any? { |t| t[:type].to_s == "manual" && text.nil? }

      triggers.any? do |t|
        case t[:type].to_s
        when "manual"
          true
        when "keyword"
          keywords = Array(t[:keywords]).map(&:to_s)
          keywords.any? { |k| text.to_s.downcase.include?(k.downcase) }
        else
          false
        end
      end
    end

    def self.find_workflows(text:, dir: "./config/riggs/workflows")
      Dir.glob(File.join(dir, "*.yml")).filter_map do |path|
        workflow = Workflow::Loader.load(path: path)
        workflow if match(workflow, text: text)
      rescue WorkflowError
        nil
      end
    end
  end
end

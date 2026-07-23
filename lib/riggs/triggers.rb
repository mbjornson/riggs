# frozen_string_literal: true

module Riggs
  module Triggers
    # text nil/blank → workflows that are manually runnable (manual trigger or no triggers).
    # text present → keyword triggers whose keywords appear in the text (manual alone does not match).
    def self.match(workflow, text:)
      triggers = Array(workflow[:triggers])
      return true if triggers.empty?

      return triggers.any? { |t| t[:type].to_s == "manual" } if text.nil? || text.to_s.strip.empty?

      triggers.any? do |t|
        case t[:type].to_s
        when "keyword"
          keywords = Array(t[:keywords]).map(&:to_s)
          keywords.any? { |k| !k.empty? && text.to_s.downcase.include?(k.downcase) }
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

    def self.list_declared(dir: "./config/riggs/workflows")
      declared = Dir.glob(File.join(dir, "*.yml")).filter_map do |path|
        workflow = Workflow::Loader.load(path: path)
        {
          name: workflow[:name],
          display_name: workflow[:display_name],
          path: path,
          triggers: Array(workflow[:triggers]).map { |t| summarize_trigger(t) }
        }
      rescue WorkflowError
        nil
      end
      declared.sort_by { |w| w[:name].to_s }
    end

    def self.summarize_trigger(t)
      type = t[:type].to_s
      h = { type: type }
      h[:keywords] = Array(t[:keywords]).map(&:to_s) if type == "keyword"
      h
    end
  end
end

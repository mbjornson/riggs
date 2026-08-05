# frozen_string_literal: true

require "psych"

module Riggs
  module Workflow
    class Loader
      MAX_TURN_PRESETS = {
        quick: 10,
        standard: 20,
        deep_research: 35
      }.freeze

      # Token budgets, replacing the former step-count window. The words are
      # kept so existing workflow YAML keeps parsing, but they now mean tokens.
      CONTEXT_BUDGETS = {
        short: 8_000,
        medium: 32_000,
        full: 128_000
      }.freeze

      def self.load(path:)
        raw = Psych.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
        cfg = Riggs::Identity.deep_symbolize(raw)
        raise WorkflowError, "Missing required field: name" unless cfg[:name]
        raise WorkflowError, "Workflow must include at least one step" if Array(cfg[:steps]).empty?

        steps = Array(cfg[:steps]).map { |s| StepNode.from_hash(s) }
        {
          name: cfg[:name].to_s,
          display_name: (cfg[:display_name] || humanize(cfg[:name])).to_s,
          description: (cfg[:description] || "").to_s,
          triggers: Array(cfg[:triggers]),
          context_window: normalize_context_window(cfg[:context_window]),
          reserve_tokens: (cfg[:reserve_tokens] || 16_384).to_i,
          keep_recent_tokens: (cfg[:keep_recent_tokens] || 20_000).to_i,
          max_llm_calls: normalize_max_turns(cfg[:max_llm_calls] || 20),
          timeout_seconds: (cfg[:timeout_seconds] || 300).to_i,
          providers: cfg[:providers] || { default: { relay_chain: ["mock"] } },
          steps: steps,
          memory_policy: cfg[:memory_scope] || { isolation: "namespaced" },
          audit_log: cfg[:audit_log] != false
        }
      end

      def self.validate(workflow)
        errors = []
        steps = workflow[:steps]
        step_keys = steps.map(&:id)

        errors << "Duplicate step ids found" if step_keys.uniq.size != step_keys.size

        steps.each do |step|
          resolve_next_targets(step.next).each do |target|
            errors << "Step '#{step.id}' references undefined step: #{target}" unless step_keys.include?(target)
          end
        end

        if steps.any?
          visited = Set.new
          rec_stack = Set.new
          detect_cycle(steps.first.id, steps, visited, rec_stack, errors)
          # Also walk from any unreachable roots for completeness
          steps.each do |s|
            next if visited.include?(s.id)

            detect_cycle(s.id, steps, visited, rec_stack, errors)
          end
        end

        {
          valid: errors.empty?,
          errors: errors,
          step_count: steps.size,
          max_depth: estimate_max_depth(steps)
        }
      end

      def self.resolve_context(input_str, context_hash)
        return input_str.to_s if input_str.nil? || !input_str.to_s.include?("{{")

        input_str.to_s.gsub(/\{\{workflow\.([\w.]+)\}\}/) do
          path = Regexp.last_match(1).split(".")
          dig_context(context_hash, path) || "<empty>"
        end
      end

      def self.resolve_next(step, outputs:, gate_decision: nil)
        current_output = outputs[step.output_var] ||
                         outputs[step.output_var.to_sym] ||
                         outputs[step.id] ||
                         outputs[step.id.to_sym]
        NextResolver.resolve(step.next, outputs: outputs, gate_decision: gate_decision, current_output: current_output)
      end

      def self.resolve_next_targets(next_val)
        NextResolver.targets(next_val)
      end

      def self.normalize_context_window(raw)
        return raw.to_i if raw.is_a?(Integer)
        return raw.to_i if raw.to_s.match?(/\A\d+\z/)

        CONTEXT_BUDGETS.fetch((raw || :medium).to_s.to_sym, CONTEXT_BUDGETS[:medium])
      end

      def self.normalize_max_turns(val)
        case val
        when Symbol, String
          key = val.to_s.to_sym
          MAX_TURN_PRESETS.fetch(key) { val.to_i.nonzero? || 20 }
        else
          val.to_i.nonzero? || 20
        end
      end

      def self.humanize(name)
        name.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
      end

      def self.dig_context(hash, path)
        cur = hash
        path.each do |part|
          return nil unless cur.is_a?(Hash)

          key = part.to_sym
          cur = cur[key] || cur[part]
        end
        cur
      end

      def self.detect_cycle(node_id, steps, visited, rec_stack, errors)
        return if visited.include?(node_id)

        if rec_stack.include?(node_id)
          errors << "Cycle detected involving step '#{node_id}'"
          return
        end

        step = steps.find { |s| s.id == node_id }
        return unless step

        rec_stack.add(node_id)
        resolve_next_targets(step.next).each do |next_id|
          detect_cycle(next_id, steps, visited, rec_stack, errors)
        end
        rec_stack.delete(node_id)
        visited.add(node_id)
      end

      def self.estimate_max_depth(steps)
        return 0 if steps.empty?

        graph = {}
        steps.each { |s| graph[s.id] = resolve_next_targets(s.next) }

        memo = {}
        dfs = lambda do |id, stack|
          return memo[id] if memo.key?(id)
          return 0 if stack.include?(id)

          kids = Array(graph[id])
          return memo[id] = 1 if kids.empty?

          memo[id] = 1 + kids.map { |k| dfs.call(k, stack + [id]) }.max
        end

        steps.map { |s| dfs.call(s.id, []) }.max || 0
      end
      private_class_method :detect_cycle, :estimate_max_depth, :dig_context
    end

    class NextResolver
      def self.targets(next_val)
        return [] if next_val.nil? || next_val.to_s.strip.empty?

        parse_clauses(next_val).map { |c| c[:target] }.compact.uniq
      end

      def self.resolve(next_val, outputs:, gate_decision: nil, current_output: nil)
        return nil if next_val.nil? || next_val.to_s.strip.empty?

        clauses = parse_clauses(next_val)
        text = current_output.to_s

        clauses.each do |clause|
          case clause[:type]
          when :plain, :else
            return clause[:target]
          when :contains
            return clause[:target] if text.include?(clause[:needle])
          when :gate_approved
            return clause[:target] if gate_decision == :approved
          when :gate_rejected
            return clause[:target] if gate_decision == :rejected
          end
        end

        # No clause matched and no else: the workflow ends here
        nil
      end

      def self.parse_clauses(next_val)
        parts = next_val.to_s.split(";").map(&:strip).reject(&:empty?)
        parts.flat_map do |part|
          part.split(",").map(&:strip).reject(&:empty?).map { |p| parse_one(p) }
        end
      end

      def self.parse_one(part)
        case part
        when /\Aif\s+contains\s+(.+?):\s*(\w+)\z/i
          { type: :contains, needle: Regexp.last_match(1).strip.delete_prefix('"').delete_suffix('"'),
            target: Regexp.last_match(2) }
        when /\Aif\s+gate\.approved:\s*(\w+)\z/i
          { type: :gate_approved, target: Regexp.last_match(1) }
        when /\Aif\s+gate\.rejected:\s*(\w+)\z/i
          { type: :gate_rejected, target: Regexp.last_match(1) }
        when /\Aelse:\s*(\w+)\z/i
          { type: :else, target: Regexp.last_match(1) }
        when /\A(\w+)\z/
          { type: :plain, target: Regexp.last_match(1) }
        else
          # "if gate.approved: target" already handled; try loose "target"
          { type: :plain, target: part.split(":").last.to_s.strip }
        end
      end
      private_class_method :parse_clauses, :parse_one
    end

    StepNode = Struct.new(
      :id, :label, :agent, :skills, :skill, :input, :output_var, :gates, :next, :max_retries, :provider,
      keyword_init: true
    ) do
      def self.from_hash(attrs)
        h = attrs.is_a?(Hash) ? Riggs::Identity.deep_symbolize(attrs) : {}
        id = (h[:id] || raise(WorkflowError, "Step missing id")).to_s
        new(
          id: id,
          label: (h[:label] || Loader.humanize(id)).to_s,
          agent: (h[:agent] || "default").to_s,
          skills: Array(h[:skills]),
          skill: h[:skill]&.to_s,
          input: (h[:input] || "").to_s,
          output_var: (h[:output_var] || "#{id}_result").to_s,
          gates: Array(h[:gates]).map(&:to_s),
          next: h[:next],
          max_retries: (h[:max_retries] || 3).to_i,
          provider: h[:provider]&.to_s
        )
      end

      def approval_gate?
        gates.map(&:to_s).include?("approval")
      end
    end
  end

  class WorkflowError < Error; end
end

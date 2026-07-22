# frozen_string_literal: true

require "stringio"

module Riggs
  class WorkflowsController < ApplicationController
    def index
      require_riggs_permission!(:read_workflow)
      @workflows = workflow_names
      render json: @workflows
    end

    def show
      require_riggs_permission!(:read_workflow)
      path = workflow_path(params[:id])
      return render(json: { error: "not found" }, status: :not_found) unless path

      workflow = Workflow::Loader.load(path: path)
      render json: {
        name: workflow[:name],
        display_name: workflow[:display_name],
        steps: workflow[:steps].map { |s| { id: s.id, label: s.label, gates: s.gates, next: s.next } }
      }
    end

    def run
      require_riggs_permission!(:run_workflow)
      path = workflow_path(params[:id])
      return render(json: { error: "not found" }, status: :not_found) unless path

      workflow = Workflow::Loader.load(path: path)
      gate_handler = ->(_step, _io) { :approved }

      raw_input = params[:input]
      input =
        if raw_input.respond_to?(:to_unsafe_h)
          raw_input.to_unsafe_h.transform_keys(&:to_sym)
        elsif raw_input.is_a?(Hash)
          raw_input.transform_keys(&:to_sym)
        else
          {}
        end

      engine = Workflow::GraphEngine.new(
        workflow: workflow,
        user_identity: riggs_identity,
        db_path: hub_config[:sqlite_path] || Rails.root.join("db/riggs.sqlite3").to_s,
        hub_config: hub_config,
        gate_handler: gate_handler,
        skill_registry: SkillRegistry.new
      )
      io = StringIO.new
      engine.execute(io, input: input)
      render json: { session_id: engine.session_id, status: engine.status, log: io.string, outputs: engine.outputs }
    end

    private

    def workflow_names
      dirs = [
        Rails.root.join("config/riggs/workflows"),
        Pathname.new(File.expand_path("../../../config/riggs/workflows", __dir__))
      ]
      dirs.flat_map { |d| Dir.glob(d.join("*.yml")).map { |p| File.basename(p, ".yml") } }.uniq
    end

    def workflow_path(name)
      candidates = [
        Rails.root.join("config/riggs/workflows/#{name}.yml"),
        File.expand_path("../../../config/riggs/workflows/#{name}.yml", __dir__)
      ]
      candidates.find { |p| File.exist?(p) }
    end
  end
end

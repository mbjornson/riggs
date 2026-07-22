# frozen_string_literal: true

module Riggs
  class MemoryController < ApplicationController
    def search
      require_riggs_permission!(:read_workflow, :configure_memory, :inspect_run)
      query = params[:q].to_s
      memory = MemoryService.new(
        namespace: riggs_identity[:memory_namespace],
        db_path: hub_config[:sqlite_path] || Rails.root.join("db/riggs.sqlite3").to_s,
        config: hub_config[:sqlite_memory] || {}
      )
      results = memory.recall(query)
      memory.close
      render json: { query: query, namespace: riggs_identity[:memory_namespace], results: Array(results) }
    end
  end
end

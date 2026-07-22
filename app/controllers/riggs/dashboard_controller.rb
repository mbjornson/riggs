# frozen_string_literal: true

module Riggs
  class DashboardController < ApplicationController
    def index
      require_riggs_permission!(:read_workflow, :inspect_run)
      @workflows = Dir.glob(File.expand_path("config/riggs/workflows/*.yml", Rails.root)).map { |p| File.basename(p, ".yml") }
      if @workflows.empty?
        @workflows = Dir.glob(File.expand_path("../../../config/riggs/workflows/*.yml", __dir__)).map do |p|
          File.basename(p, ".yml")
        end
      end
      render :index
    end
  end
end

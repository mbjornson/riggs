# frozen_string_literal: true

module Riggs
  # @deprecated Use GET/POST /api/workflows via Riggs::Web::App.
  class WorkflowsController < ApplicationController
    def index
      head :gone
    end

    def show
      head :gone
    end

    def run
      head :gone
    end
  end
end

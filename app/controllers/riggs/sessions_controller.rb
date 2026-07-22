# frozen_string_literal: true

module Riggs
  # @deprecated Use /api/sessions via Riggs::Web::App.
  class SessionsController < ApplicationController
    def show
      head :gone
    end

    def audit
      head :gone
    end

    def approve
      head :gone
    end

    def reject
      head :gone
    end
  end
end

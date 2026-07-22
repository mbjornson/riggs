# frozen_string_literal: true

module Riggs
  # @deprecated Use /api/memory/search via Riggs::Web::App.
  class MemoryController < ApplicationController
    def search
      head :gone
    end
  end
end

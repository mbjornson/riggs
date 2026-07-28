# frozen_string_literal: true

module Riggs
  # @deprecated Use Riggs::Web::App via Engine mount or `riggs serve`.
  class DashboardController < ApplicationController
    def index
      redirect_to "/"
    end
  end
end

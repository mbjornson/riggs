# frozen_string_literal: true

# DEPRECATED: Phase 4 serves HTML/JSON via Riggs::Web::App (Rack).
# These Rails controllers are retained only for reference / older mounts.
# Prefer: mount Riggs::Engine => "/riggs" (Engine routes → Web::App).
module Riggs
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception
  end
end

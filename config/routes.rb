# frozen_string_literal: true

# Thin mount: all HTML + JSON API is served by Riggs::Web::App (same as `riggs serve`).
# Host apps:
#   mount Riggs::Engine => "/riggs"
# Optional identity mapping:
#   Riggs.identity_mapper = ->(req) { current_user&.riggs_user_id }
Riggs::Engine.routes.draw do
  mount Riggs::Web::App => "/"
end

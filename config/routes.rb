# frozen_string_literal: true

Riggs::Engine.routes.draw do
  root to: "dashboard#index"

  resources :workflows, only: %i[index show] do
    member do
      post :run
    end
  end

  resources :sessions, only: %i[show] do
    member do
      post :approve
      post :reject
      get :audit
    end
  end

  get "memory/search", to: "memory#search"
end

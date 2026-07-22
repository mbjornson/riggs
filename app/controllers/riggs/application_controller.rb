# frozen_string_literal: true

module Riggs
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    helper_method :riggs_identity

    private

    def riggs_identity
      @riggs_identity ||= begin
        user = if respond_to?(:current_user, true) && current_user
                 current_user.try(:riggs_user_id) || current_user.try(:id) || current_user.to_s
               else
                 request.headers["X-Riggs-User"] || params[:user] || Identity.load_config[:default_user]
               end
        Identity.resolve(cli_user: user.to_s)
      rescue Riggs::Error
        Identity.resolve(cli_user: Identity.load_config[:default_user])
      end
    end

    def require_riggs_permission!(*perms)
      return if Identity.permitted?(riggs_identity, *perms) ||
                perms.flatten.map(&:to_s).any? { |p| riggs_identity[:permissions].include?(p) }

      render plain: "Forbidden", status: :forbidden
    end

    def hub_config
      @hub_config ||= Identity.load_config
    rescue Riggs::Error
      { sqlite_path: Rails.root.join("db/riggs.sqlite3").to_s }
    end

    def storage
      @storage ||= Storage.new(db_path: hub_config[:sqlite_path] || Rails.root.join("db/riggs.sqlite3").to_s)
    end
  end
end

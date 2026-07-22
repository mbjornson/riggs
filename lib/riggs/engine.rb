# frozen_string_literal: true

module Riggs
  # Soft-load Rails engine only when Rails is available.
  if defined?(::Rails::Engine)
    class Engine < ::Rails::Engine
      isolate_namespace Riggs
      engine_name "riggs"

      initializer "riggs.assets" do
        # no-op; keep mountable
      end

      config.after_initialize do
        # Ensure SQLite schema exists for host app
        path = begin
          Identity.load_config[:sqlite_path]
        rescue StandardError
          nil
        end
        path ||= (defined?(Rails) ? Rails.root.join("db/riggs.sqlite3").to_s : "./db/riggs.sqlite3")
        Storage.new(db_path: path).close
      rescue StandardError
        nil
      end
    end
  end
end

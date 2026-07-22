# frozen_string_literal: true

require "psych"
require "fileutils"
require "time"

module Riggs
  # Safe read/merge/write for .agent_hubrc (never silent clobber).
  class ConfigStore
    SECRET_KEY_HINTS = /(api_key|token|password|secret|credential)/i

    def initialize(path: nil)
      @path = path || Identity.config_path || File.expand_path(".agent_hubrc")
    end

    attr_reader :path

    def read
      raise Error, "Missing config at #{@path}. Run 'riggs setup' first." unless File.exist?(@path)

      Identity.load_config(@path)
    end

    # Public view with secrets masked
    def public_view
      mask_secrets(deep_stringify(read))
    end

    # Deep-merge patch into existing config and write with backup.
    def merge!(patch)
      raise Error, "Missing config at #{@path}" unless File.exist?(@path)

      merged = deep_merge(deep_stringify(read), normalize_patch(patch))
      write!(merged)
      read
    end

    def write!(config_hash)
      raise Error, "Missing config at #{@path}" unless File.exist?(@path)

      backup!
      File.write(@path, Psych.dump(deep_stringify(config_hash)))
      @path
    end

    def backup!
      return unless File.exist?(@path)

      stamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      FileUtils.cp(@path, "#{@path}.bak.#{stamp}")
    end

    private

    def normalize_patch(patch)
      case patch
      when Hash
        patch.each_with_object({}) do |(k, v), h|
          h[k.to_s] = normalize_patch(v)
        end
      when Array
        patch.map { |v| normalize_patch(v) }
      else
        patch
      end
    end

    def deep_merge(base, overlay)
      return overlay unless base.is_a?(Hash) && overlay.is_a?(Hash)

      base.merge(overlay) do |_k, old_v, new_v|
        if old_v.is_a?(Hash) && new_v.is_a?(Hash)
          deep_merge(old_v, new_v)
        else
          new_v
        end
      end
    end

    def deep_stringify(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array
        obj.map { |v| deep_stringify(v) }
      else
        obj
      end
    end

    def mask_secrets(obj, parent_key = nil)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          key = k.to_s
          h[key] =
            if secret_key?(key) && !v.nil? && !v.to_s.empty?
              "••••••••"
            else
              mask_secrets(v, key)
            end
        end
      when Array
        obj.map { |v| mask_secrets(v, parent_key) }
      else
        obj
      end
    end

    def secret_key?(key)
      key.match?(SECRET_KEY_HINTS)
    end
  end
end

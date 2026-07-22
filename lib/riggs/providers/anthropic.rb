# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "base"

module Riggs
  module Providers
    class Anthropic < Base
      DEFAULT_MODEL = "claude-sonnet-4-20250514"
      API_URL = "https://api.anthropic.com/v1/messages"

      def complete(messages:, system: nil, timeout: 60)
        api_key = options[:api_key] || ENV["ANTHROPIC_API_KEY"]
        raise Error, "ANTHROPIC_API_KEY not set" if api_key.nil? || api_key.empty?

        model = options[:model] || DEFAULT_MODEL
        body = {
          model: model,
          max_tokens: (options[:max_tokens] || 1024).to_i,
          messages: normalize_messages(messages)
        }
        body[:system] = system if system && !system.empty?

        uri = URI(API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(uri)
        req["content-type"] = "application/json"
        req["x-api-key"] = api_key
        req["anthropic-version"] = "2023-06-01"
        req.body = JSON.generate(body)

        res = http.request(req)
        handle_response(res)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, e.message
      end

      private

      def normalize_messages(messages)
        messages.map { |m| { role: m[:role].to_s, content: m[:content].to_s } }
      end

      def handle_response(res)
        case res.code.to_i
        when 200
          data = JSON.parse(res.body)
          text = Array(data["content"]).map { |c| c["text"] }.compact.join
          {
            provider: name,
            content: text,
            usage: data["usage"] || {},
            raw: data
          }
        when 429
          raise RateLimitError, "Anthropic rate limited: #{res.body}"
        else
          raise Error, "Anthropic error #{res.code}: #{res.body}"
        end
      end
    end
  end
end

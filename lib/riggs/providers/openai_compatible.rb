# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "base"

module Riggs
  module Providers
    # OpenAI-compatible chat completions (OpenAI, Ollama, LM Studio, etc.)
    class OpenAICompatible < Base
      DEFAULT_MODEL = "gpt-4o-mini"

      def complete(messages:, system: nil, timeout: 60)
        api_key = options[:api_key] || ENV["OPENAI_API_KEY"] || ENV["OLLAMA_API_KEY"]
        base = options[:base_url] || ENV["OPENAI_BASE_URL"] || "https://api.openai.com/v1"
        model = options[:model] || DEFAULT_MODEL

        msgs = []
        msgs << { role: "system", content: system } if system && !system.empty?
        messages.each { |m| msgs << { role: m[:role].to_s, content: m[:content].to_s } }

        uri = URI("#{base.to_s.chomp('/')}/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(uri)
        req["content-type"] = "application/json"
        req["authorization"] = "Bearer #{api_key}" if api_key && !api_key.empty?
        req.body = JSON.generate({ model: model, messages: msgs })

        res = http.request(req)
        handle_response(res)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, e.message
      end

      private

      def handle_response(res)
        case res.code.to_i
        when 200
          data = JSON.parse(res.body)
          content = data.dig("choices", 0, "message", "content").to_s
          {
            provider: name,
            content: content,
            usage: data["usage"] || {},
            raw: data
          }
        when 429
          raise RateLimitError, "OpenAI-compatible rate limited: #{res.body}"
        else
          raise Error, "OpenAI-compatible error #{res.code}: #{res.body}"
        end
      end
    end
  end
end

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

      def complete(messages:, system: nil, timeout: 60, tools: nil)
        api_key = options[:api_key] || ENV["OPENAI_API_KEY"] || ENV.fetch("OLLAMA_API_KEY", nil)
        base = options[:base_url] || ENV["OPENAI_BASE_URL"] || "https://api.openai.com/v1"
        model = options[:model] || DEFAULT_MODEL

        msgs = normalize_messages(messages, system: system)
        body = { model: model, messages: msgs }
        body[:tools] = openai_tools(tools) if tools && !tools.empty?

        return options[:http_client].call(body) if options[:http_client]

        uri = URI("#{base.to_s.chomp('/')}/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(uri)
        req["content-type"] = "application/json"
        req["authorization"] = "Bearer #{api_key}" if api_key && !api_key.empty?
        req.body = JSON.generate(body)

        res = http.request(req)
        handle_response(res)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, e.message
      end

      private

      def openai_tools(tools)
        Array(tools).map do |t|
          h = t.is_a?(Hash) ? Identity.deep_symbolize(t) : {}
          {
            type: "function",
            function: {
              name: h[:name].to_s,
              description: h[:description].to_s,
              parameters: h[:input_schema] || { type: "object", properties: {} }
            }
          }
        end
      end

      def normalize_messages(messages, system: nil)
        msgs = []
        msgs << { role: "system", content: system } if system && !system.empty?
        messages.each do |m|
          role = m[:role].to_s
          case role
          when "tool"
            msgs << {
              role: "tool",
              tool_call_id: m[:tool_call_id] || m[:id],
              content: m[:content].to_s
            }
          when "assistant"
            msg = { role: "assistant", content: m[:content].to_s }
            if m[:tool_calls] && !m[:tool_calls].empty?
              msg[:tool_calls] = m[:tool_calls].map do |tc|
                {
                  id: tc[:id],
                  type: "function",
                  function: {
                    name: tc[:name],
                    arguments: JSON.generate(tc[:arguments] || {})
                  }
                }
              end
            end
            msgs << msg
          else
            msgs << { role: role, content: m[:content].to_s }
          end
        end
        msgs
      end

      def handle_response(res)
        case res.code.to_i
        when 200
          data = JSON.parse(res.body)
          message = data.dig("choices", 0, "message") || {}
          content = message["content"].to_s
          tool_calls = Array(message["tool_calls"]).map do |tc|
            args = tc.dig("function", "arguments")
            parsed = if args.is_a?(String)
                       begin
                         JSON.parse(args)
                       rescue StandardError
                         {}
                       end
                     else
                       args || {}
                     end
            {
              id: tc["id"],
              name: tc.dig("function", "name"),
              arguments: parsed
            }
          end
          {
            provider: name,
            content: content,
            tool_calls: tool_calls,
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

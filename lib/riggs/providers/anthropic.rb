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

      def complete(messages:, system: nil, timeout: 60, tools: nil)
        api_key = options[:api_key] || ENV.fetch("ANTHROPIC_API_KEY", nil)
        raise Error, "ANTHROPIC_API_KEY not set" if api_key.nil? || api_key.empty?

        model = options[:model] || DEFAULT_MODEL
        body = {
          model: model,
          max_tokens: (options[:max_tokens] || 1024).to_i,
          messages: normalize_messages(messages)
        }
        body[:system] = system if system && !system.empty?
        body[:tools] = anthropic_tools(tools) if tools && !tools.empty?

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

        return options[:http_client].call(body) if options[:http_client]

        res = http.request(req)
        handle_response(res)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, e.message
      end

      private

      def anthropic_tools(tools)
        Array(tools).map do |t|
          h = t.is_a?(Hash) ? Identity.deep_symbolize(t) : {}
          {
            name: h[:name].to_s,
            description: h[:description].to_s,
            input_schema: h[:input_schema] || { type: "object", properties: {} }
          }
        end
      end

      def normalize_messages(messages)
        messages.map do |m|
          role = m[:role].to_s
          case role
          when "tool"
            {
              role: "user",
              content: [{
                type: "tool_result",
                tool_use_id: m[:tool_call_id] || m[:id],
                content: m[:content].to_s
              }]
            }
          when "assistant"
            if m[:tool_calls] && !m[:tool_calls].empty?
              blocks = []
              blocks << { type: "text", text: m[:content].to_s } unless m[:content].to_s.empty?
              m[:tool_calls].each do |tc|
                blocks << {
                  type: "tool_use",
                  id: tc[:id],
                  name: tc[:name],
                  input: tc[:arguments] || {}
                }
              end
              { role: "assistant", content: blocks }
            else
              { role: "assistant", content: m[:content].to_s }
            end
          else
            { role: role == "system" ? "user" : role, content: m[:content].to_s }
          end
        end
      end

      def handle_response(res)
        case res.code.to_i
        when 200
          data = JSON.parse(res.body)
          parse_anthropic_content(data)
        when 429
          raise RateLimitError, "Anthropic rate limited: #{res.body}"
        else
          raise Error, "Anthropic error #{res.code}: #{res.body}"
        end
      end

      def parse_anthropic_content(data)
        blocks = Array(data["content"])
        text = blocks.select { |c| c["type"] == "text" }.map { |c| c["text"] }.compact.join
        tool_calls = blocks.select { |c| c["type"] == "tool_use" }.map do |c|
          {
            id: c["id"],
            name: c["name"],
            arguments: c["input"] || {}
          }
        end
        {
          provider: name,
          model: data["model"] || options[:model],
          content: text,
          tool_calls: tool_calls,
          usage: data["usage"] || {},
          raw: data
        }
      end
    end
  end
end

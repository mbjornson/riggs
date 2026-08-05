# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "base"

module Riggs
  module Providers
    # Cursor Cloud Agents REST API — create agent, poll run, optional cancel on timeout.
    class CursorCloud < Base
      DEFAULT_BASE = "https://api.cursor.com"
      TERMINAL = %w[FINISHED ERROR CANCELLED EXPIRED].freeze
      SUCCESS = "FINISHED"

      def complete(messages:, system: nil, timeout: 60, tools: nil)
        api_key = options[:api_key] || ENV.fetch("CURSOR_API_KEY", nil)
        raise Error, "CURSOR_API_KEY not set" if api_key.nil? || api_key.empty?

        repos = Array(options[:repos])
        raise Error, "cursor_cloud requires providers.cursor_cloud.repos (at least one repo url)" if repos.empty?

        agent_id = nil
        run_id = nil
        prompt = build_prompt(messages: messages, system: system)
        created = create_agent!(api_key: api_key, prompt: prompt, repos: repos)
        agent_id = created.dig("agent", "id") || created["id"]
        run_id = created.dig("run", "id") || created.dig("agent", "latestRunId")
        raise Error, "cursor_cloud create did not return agent/run id: #{created.inspect}" if agent_id.nil? || run_id.nil?

        run = poll_run!(api_key: api_key, agent_id: agent_id, run_id: run_id, timeout: timeout)
        status = run["status"].to_s.upcase
        raise Error, "cursor_cloud run #{status}: #{run['result'] || run.inspect}" unless status == SUCCESS

        {
          provider: name,
          model: options[:model],
          content: run["result"].to_s,
          usage: { duration_ms: run["durationMs"] },
          raw: run
        }
      rescue TimeoutError
        cancel_run(api_key: api_key, agent_id: agent_id, run_id: run_id) if api_key && agent_id && run_id
        raise
      end

      private

      def build_prompt(messages:, system:)
        parts = []
        parts << system.to_s unless system.to_s.empty?
        Array(messages).each do |m|
          role = m[:role] || m["role"]
          content = m[:content] || m["content"]
          parts << "#{role}: #{content}"
        end
        parts.join("\n\n")
      end

      def create_agent!(api_key:, prompt:, repos:)
        body = {
          prompt: { text: prompt },
          model: model_payload,
          repos: normalize_repos(repos),
          mode: (options[:mode] || "agent").to_s
        }
        body[:autoCreatePR] = options[:auto_create_pr] if options.key?(:auto_create_pr)

        request_json(:post, "/v1/agents", api_key: api_key, body: body)
      end

      def model_payload
        model = options[:model] || "composer-2.5"
        if model.is_a?(Hash)
          Identity.deep_symbolize(model).transform_keys(&:to_s)
        else
          { "id" => model.to_s }
        end
      end

      def normalize_repos(repos)
        repos.map do |r|
          h = Identity.deep_symbolize(r.is_a?(Hash) ? r : { url: r })
          out = { "url" => h[:url].to_s }
          out["startingRef"] = h[:starting_ref] || h[:startingRef] if h[:starting_ref] || h[:startingRef]
          out
        end
      end

      def poll_run!(api_key:, agent_id:, run_id:, timeout:)
        deadline = Time.now + timeout.to_f
        interval = (options[:poll_interval_seconds] || 5).to_f

        loop do
          run = request_json(:get, "/v1/agents/#{agent_id}/runs/#{run_id}", api_key: api_key)
          status = run["status"].to_s.upcase
          return run if TERMINAL.include?(status)

          raise TimeoutError, "cursor_cloud poll timed out after #{timeout}s" if Time.now >= deadline

          remaining = [deadline - Time.now, 0.1].max
          sleep([interval, remaining].min)
        end
      end

      def cancel_run(api_key:, agent_id:, run_id:)
        request_json(:post, "/v1/agents/#{agent_id}/runs/#{run_id}/cancel", api_key: api_key, body: {})
      rescue StandardError
        nil
      end

      def request_json(method, path, api_key:, body: nil)
        # Allow tests to inject a fake HTTP layer
        return options[:http_client].call(method, path, body) if options[:http_client]

        base = (options[:base_url] || DEFAULT_BASE).to_s.chomp("/")
        uri = URI("#{base}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 30
        http.read_timeout = 60

        res = http.request(build_request(method, uri, api_key: api_key, body: body))
        handle_response(res)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, e.message
      end

      def build_request(method, uri, api_key:, body: nil)
        req =
          case method
          when :get then Net::HTTP::Get.new(uri)
          when :post then Net::HTTP::Post.new(uri)
          else raise Error, "unsupported method #{method}"
          end

        req["content-type"] = "application/json"
        req["authorization"] = "Bearer #{api_key}"
        req.body = JSON.generate(body) if body
        req
      end

      def handle_response(res)
        code = res.code.to_i
        case code
        when 200, 201
          JSON.parse(res.body)
        when 429
          raise RateLimitError, "cursor_cloud rate limited: #{res.body}"
        else
          raise Error, "cursor_cloud error #{code}: #{res.body}"
        end
      end
    end
  end
end

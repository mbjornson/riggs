# frozen_string_literal: true

require_relative "base"

module Riggs
  module Providers
    class Mock < Base
      def complete(messages:, system: nil, timeout: 60, tools: nil)
        user_text = messages.rfind { |m| m[:role].to_s == "user" }&.dig(:content).to_s
        # After tool results, prefer last user/tool message content
        tool_msgs = messages.select { |m| %w[tool user].include?(m[:role].to_s) }
        last_tool = tool_msgs.last

        if last_tool && last_tool[:role].to_s == "tool"
          return {
            provider: name,
            model: options[:model],
            content: "classification=OK; used_tool=#{last_tool[:name]}; result=#{last_tool[:content].to_s[0, 80]}",
            tool_calls: [],
            usage: {}
          }
        end

        probe = if user_text =~ /Ticket:\s*(.+)\z/m
                  Regexp.last_match(1)
                else
                  user_text
                end
        snippet = probe[0, 120]

        # If tools available and text asks to lookup/search, emit a tool call once
        if tools && !tools.empty? && probe.match?(/\b(lookup|search|runbook|TOOL:)/i) && messages.none? do |m|
          m[:role].to_s == "tool"
        end
          tool = Array(tools).find { |t| t[:name].to_s.include?("lookup") || t[:name].to_s.include?("search") } || tools.first
          tname = tool[:name] || tool["name"]
          return {
            provider: name,
            model: options[:model],
            content: "",
            tool_calls: [{
              id: "mock_#{SecureRandom.hex(4)}",
              name: tname.to_s,
              arguments: { topic: "oauth", query: snippet[0, 40] }
            }],
            usage: {}
          }
        end

        if user_text.start_with?("TOOL:")
          return {
            provider: name,
            model: options[:model],
            content: user_text,
            tool_calls: parse_tool_line(user_text),
            usage: {}
          }
        end

        body = if probe.match?(/\bERROR\b|outage|database down|segfault/i)
                 "classification=ERROR; action=escalate; input=#{snippet}"
               elsif user_text.match?(/approve|gate/i)
                 "Ready for human review. Draft response prepared."
               else
                 "classification=OK; summary=#{snippet.empty? ? 'empty' : snippet}"
               end

        tool_calls = parse_tool_line(body)
        usage = { prompt_tokens: user_text.length, completion_tokens: body.length }
        {
          provider: name,
          model: options[:model],
          content: tool_calls.empty? ? body : "",
          tool_calls: tool_calls,
          usage: usage,
          raw: { usage: usage }
        }
      end
    end
  end
end

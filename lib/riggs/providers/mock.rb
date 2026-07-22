# frozen_string_literal: true

require_relative "base"

module Riggs
  module Providers
    class Mock < Base
      def complete(messages:, system: nil, timeout: 60)
        user_text = messages.reverse.find { |m| m[:role].to_s == "user" }&.dig(:content).to_s
        # Prefer the ticket payload after "Ticket:" if present, else full user text
        probe = if user_text =~ /Ticket:\s*(.+)\z/m
                  Regexp.last_match(1)
                else
                  user_text
                end
        snippet = probe[0, 120]
        body = if probe.match?(/\bERROR\b|outage|database down|segfault/i)
                 "classification=ERROR; action=escalate; input=#{snippet}"
               elsif user_text.match?(/approve|gate/i)
                 "Ready for human review. Draft response prepared."
               else
                 "classification=OK; summary=#{snippet.empty? ? 'empty' : snippet}"
               end
        {
          provider: name,
          content: body,
          usage: { prompt_tokens: user_text.length, completion_tokens: body.length }
        }
      end
    end
  end
end

# frozen_string_literal: true

require "json"

module Riggs
  # Formats `riggs_audit` rows into stable event objects for the HTTP event
  # stream (poll + SSE) and the live web log.
  module Events
    # A run is over — and its stream can close — only at these statuses.
    # "paused" is deliberately absent: a paused run is resumable.
    TERMINAL_STATUSES = %w[completed failed rejected].freeze

    DEFAULT_LIMIT = 500
    MAX_LIMIT = 1000

    # session_id: is a fallback for rows selected without that column
    # (Storage#list_audit_after), where the caller already knows the session.
    def self.normalize(row, session_id: nil)
      {
        id: field(row, "id").to_i,
        type: field(row, "event_type").to_s,
        session_id: (field(row, "session_id") || session_id).to_s,
        at: field(row, "created_at").to_s,
        payload: parse_payload(field(row, "payload"))
      }
    end

    def self.to_jsonl(row, session_id: nil)
      JSON.generate(normalize(row, session_id: session_id))
    end

    # A blank limit means "the default page"; anything else is read as an
    # integer and pinned into 1..MAX_LIMIT, so garbage cannot widen a page.
    def self.clamp_limit(raw)
      return DEFAULT_LIMIT if raw.nil? || raw.to_s.strip.empty?

      raw.to_s.to_i.clamp(1, MAX_LIMIT)
    end

    def self.terminal?(status)
      TERMINAL_STATUSES.include?(status.to_s)
    end

    # A stored payload that is not a JSON object is surfaced verbatim rather
    # than raised on: an unreadable event is still an event.
    def self.parse_payload(raw)
      return {} if raw.nil? || raw.to_s.strip.empty?

      parsed = JSON.parse(raw.to_s)
      parsed.is_a?(Hash) ? parsed : { "raw" => raw.to_s }
    rescue JSON::ParserError
      { "raw" => raw.to_s }
    end

    def self.field(row, key)
      return nil unless row.respond_to?(:[])

      row[key].nil? ? row[key.to_sym] : row[key]
    end
  end
end

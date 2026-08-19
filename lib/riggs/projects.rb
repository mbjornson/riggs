# frozen_string_literal: true

require "time"

module Riggs
  # Every project riggs knows about, from the UNION of two sources that
  # disagree: the paths registered in trust.yml, and the paths sessions
  # actually recorded. A trusted path that never ran appears only in the first;
  # a path that ran and was later forgotten appears only in the second.
  # Reporting either alone omits real projects.
  class Projects
    def initialize(storage:, trust:)
      @storage = storage
      @trust = trust
    end

    def rows
      paths.map { |path| row_for(path) }
    end

    private

    # nil is the (unattributed) bucket -- sessions written before the column
    # existed -- and sorts last so it reads as a footer rather than a project
    # named "(".
    def paths
      (@trust.projects + totals.keys).uniq.sort_by { |path| [path.nil? ? 1 : 0, path.to_s] }
    end

    def totals
      @totals ||= @storage.project_totals.to_h { |row| [row["project_path"], row] }
    end

    def row_for(path)
      total = totals[path] || {}
      { path: path, trusted: @trust.trusted?(path), exists: exists?(path),
        runs: total["runs"].to_i, last_run: total["last_run"], cost_usd: total["cost_usd"],
        priced_calls: total["priced_calls"].to_i,
        unmetered_calls: total["calls"].to_i - total["priced_calls"].to_i }
    end

    # The unattributed bucket is not a path, so it is never "missing".
    def exists?(path)
      return true if path.nil?

      File.directory?(path)
    end

    class Table
      HEADER = ["PATH", "TRUST", "RUNS", "LAST RUN", "SPEND", ""].freeze

      # RUNS is a count, and counts compare by eye only when their digits line
      # up. Everything else reads left to right.
      RIGHT_ALIGNED = [HEADER.index("RUNS")].freeze

      def self.render(rows)
        TextTable.render(header: HEADER, right_aligned: RIGHT_ALIGNED,
                         rows: rows.map { |row| Row.new(row).cells })
      end
    end

    # One report row rendered.
    class Row
      UNATTRIBUTED = "(unattributed)"
      NONE = "—"
      MISSING = "⚠ path missing"

      def initialize(row)
        @row = row
      end

      def cells
        [path, trust, @row[:runs].to_s, last_run, spend, warning]
      end

      private

      def path
        return UNATTRIBUTED if @row[:path].nil?

        @row[:path]
      end

      def trust
        return NONE if @row[:path].nil?
        return "trusted" if @row[:trusted]

        "not trusted"
      end

      def last_run
        return NONE if @row[:last_run].nil?

        Ago.of(@row[:last_run])
      end

      def spend
        Spend.of(cost_usd: @row[:cost_usd], unmetered_calls: @row[:unmetered_calls])
      end

      def warning
        return "" if @row[:exists]

        MISSING
      end
    end

    # Relative rather than absolute: the question a roll-up answers is "is this
    # project still live", and an ISO timestamp makes the reader do the
    # subtraction.
    class Ago
      SCALES = [[86_400 * 7, "w"], [86_400, "d"], [3600, "h"], [60, "m"]].freeze

      def self.of(timestamp)
        new(timestamp).to_s
      end

      def initialize(timestamp)
        @timestamp = timestamp
      end

      def to_s
        return "just now" if seconds < 60

        scale = SCALES.detect { |size, _| seconds >= size }
        "#{seconds / scale.first}#{scale.last} ago"
      end

      private

      # SQLite writes CURRENT_TIMESTAMP as UTC without a zone marker, so it is
      # parsed as UTC explicitly. Reading it as local time would report a run
      # from an hour ago as hours in the future.
      def seconds
        @seconds ||= [(Time.now.utc - Time.parse("#{@timestamp} UTC")).to_i, 0].max
      end
    end
  end
end

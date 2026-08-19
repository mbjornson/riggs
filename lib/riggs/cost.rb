# frozen_string_literal: true

module Riggs
  # R11.6's spend report. Grouping by project IS this command's purpose rather
  # than a mode of it, which is why there is no --by-project flag to forget.
  class Cost
    def initialize(storage:, trust:, cwd:)
      @storage = storage
      @trust = trust
      @cwd = cwd
    end

    def lines(query)
      return Scoped.new(storage: @storage, path: selected(query)).lines if query

      Overview.new(rows).lines
    end

    private

    def selected(query)
      Selector.resolve(query: query, paths: rows.map { |row| row[:path] }, cwd: @cwd)
    end

    # Projects with no runs are omitted here and reported by `riggs projects`.
    # They contribute nothing to the total, so this narrows what is shown
    # without changing what is counted.
    def rows
      @rows ||= Projects.new(storage: @storage, trust: @trust).rows.reject { |row| row[:runs].zero? }
    end

    # Which project the operator meant. Never a silent pick: two products both
    # checked out as `web` is ordinary, and guessing between them misreports
    # spend -- worse than a refusal, because nothing about the figure looks
    # wrong.
    class Selector
      def self.resolve(query:, paths:, cwd:)
        new(query: query, paths: paths, cwd: cwd).resolved
      end

      def initialize(query:, paths:, cwd:)
        @query = query.to_s
        @paths = paths
        @cwd = cwd
      end

      def resolved
        return exact(Config::Resolver.project_path(@cwd)) if @query == "."
        return exact(@query) if @query.start_with?(File::SEPARATOR)

        by_basename
      end

      private

      def exact(path)
        return path if @paths.include?(path)

        raise Error, "No recorded spend for #{path}. Run 'riggs projects' to see what riggs knows about."
      end

      def by_basename
        matches = @paths.compact.select { |path| File.basename(path) == @query }
        raise Error, ambiguous(matches) if matches.size > 1
        raise Error, "No project named #{@query.inspect}. Run 'riggs projects' to see what riggs knows about." if
          matches.empty?

        exact(matches.first)
      end

      def ambiguous(matches)
        "#{@query.inspect} matches more than one project:\n" \
          "#{matches.map { |path| "  #{path}" }.join("\n")}\nName the full path."
      end
    end

    # Every project, grouped, with a total. The total includes the
    # (unattributed) bucket: a roll-up that omits history is a wrong total, not
    # a partial one.
    class Overview
      HEADER = %w[PATH RUNS SPEND].freeze
      RIGHT_ALIGNED = [HEADER.index("RUNS")].freeze

      def initialize(rows)
        @rows = rows
      end

      def lines
        TextTable.render(header: HEADER, right_aligned: RIGHT_ALIGNED, rows: @rows.map { |row| cells(row) } + [total])
      end

      private

      def cells(row)
        [Projects::Row.new(row).cells.first, row[:runs].to_s,
         Spend.of(cost_usd: row[:cost_usd], unmetered_calls: row[:unmetered_calls])]
      end

      def total
        ["TOTAL", @rows.sum { |row| row[:runs] }.to_s,
         Spend.of(cost_usd: priced_total, unmetered_calls: @rows.sum { |row| row[:unmetered_calls] })]
      end

      # nil, not 0, when nothing was priced -- summing an empty set of NULLs to
      # a zero is exactly the false record Spend exists to prevent.
      def priced_total
        priced = @rows.map { |row| row[:cost_usd] }.compact
        return nil if priced.empty?

        priced.sum
      end
    end

    # One project, broken down by provider.
    class Scoped
      HEADER = %w[PROVIDER CALLS SPEND].freeze
      RIGHT_ALIGNED = [HEADER.index("CALLS")].freeze

      def initialize(storage:, path:)
        @storage = storage
        @path = path
      end

      def lines
        ["#{@path}\n"] + TextTable.render(header: HEADER, right_aligned: RIGHT_ALIGNED, rows: rows)
      end

      private

      def rows
        @storage.provider_totals(@path).map { |row| cells(row) }
      end

      def cells(row)
        [row["provider"].to_s, row["calls"].to_s,
         Spend.of(cost_usd: row["cost_usd"], unmetered_calls: row["calls"].to_i - row["priced_calls"].to_i)]
      end
    end
  end
end

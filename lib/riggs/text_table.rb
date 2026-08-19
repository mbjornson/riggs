# frozen_string_literal: true

module Riggs
  # Fixed-width columns measured from the content rather than declared, so one
  # long checkout path does not silently shift every column right of it.
  #
  # Generic on purpose: `riggs projects` and `riggs cost` both print aligned
  # rows, and a second copy of this arithmetic is how two reports come to
  # disagree about what a column means.
  class TextTable
    def self.render(header:, rows:, right_aligned: [])
      new(header: header, rows: rows, right_aligned: right_aligned).lines
    end

    def initialize(header:, rows:, right_aligned:)
      @cells = [header] + rows
      @right_aligned = right_aligned
    end

    def lines
      @cells.map { |cells| padded(cells) }
    end

    private

    def padded(cells)
      cells.each_with_index.map { |cell, index| justified(cell.to_s, index) }.join("  ").rstrip
    end

    # Counts and amounts compare by eye only when their digits line up.
    def justified(cell, index)
      return cell.rjust(widths[index]) if @right_aligned.include?(index)

      cell.ljust(widths[index])
    end

    def widths
      @widths ||= @cells.transpose.map { |column| column.map { |cell| cell.to_s.length }.max }
    end
  end
end

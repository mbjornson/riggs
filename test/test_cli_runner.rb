# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "stringio"

class TestCliRunner < Minitest::Test
  # Closing stdout/stderr while the reader threads are still in IO#read
  # raises IOError ("stream closed in another thread") from those threads.
  # Timeout must join or kill the readers first. The child writes nothing so
  # the readers stay blocked on read until the pipes are closed.
  def test_timeout_does_not_report_stream_closed_from_reader_threads
    reports = []
    8.times do
      captured = StringIO.new
      previous = $stderr
      $stderr = captured
      begin
        assert_raises(Riggs::Providers::TimeoutError) do
          Riggs::Providers::CliRunner.run(
            command: RbConfig.ruby,
            args: ["-e", "sleep 30"],
            timeout: 0.15
          )
        end
        sleep 0.05
      ensure
        $stderr = previous
      end
      reports << captured.string if captured.string.include?("stream closed in another thread")
    end

    assert_empty reports, reports.first
  end
end

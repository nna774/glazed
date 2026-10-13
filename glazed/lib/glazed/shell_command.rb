# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'open3'
require 'glazed'

module Glazed
  # Runs a command line with /bin/sh -c, feeding stdin and capturing stdout.
  #
  # @example
  #   Glazed::ShellCommand.new(run: 'sort', env: {}, stdin: "b\na\n", timeout: 10).call #=> "a\nb\n"
  class ShellCommand
    # Raised when the command exits non-zero or is killed by a signal.
    class Failed < Glazed::Error; end

    # Bytes of stderr kept in error messages.
    STDERR_TAIL = 1000 #: Integer
    # Seconds between SIGTERM and SIGKILL when the command overruns.
    KILL_GRACE = 5 #: Integer

    # @param run [String] command line
    # @param env [Hash{String => String}] environment added to the inherited one
    # @param stdin [String] data written to stdin
    # @param timeout [Numeric] seconds before the command is killed
    #: (run: String, env: Hash[String, String], stdin: String, timeout: Numeric) -> void
    def initialize(run:, env:, stdin:, timeout:)
      @run = run #: String
      @env = env #: Hash[String, String]
      @stdin = stdin #: String
      @timeout = timeout #: Numeric
    end

    # Runs the command to completion.
    #
    # @return [String] stdout
    # @raise [Failed] when the command exits non-zero or is killed by a signal
    # @raise [TimeoutError] when the command does not finish in time; its process group is killed
    #: () -> String
    def call
      stdin, stdout, stderr, waiter = Open3.popen3(@env, '/bin/sh', '-c', @run, pgroup: true)
      begin
        writer = Thread.new do
          stdin.write(@stdin)
        rescue Errno::EPIPE
          # The command exited or closed stdin without reading all of it.
          nil
        ensure
          stdin.close
        end
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }

        unless waiter.join(@timeout.to_f)
          terminate(waiter)
          raise TimeoutError, "#{@run.inspect} did not finish in #{@timeout}s"
        end
        writer.join
        status = waiter.value #: Process::Status
        output = out.value.to_s
        return output if status.success?

        raise Failed, "#{@run.inspect} #{describe(status)}: #{err.value.to_s[-STDERR_TAIL..] || err.value}"
      ensure
        [stdin, stdout, stderr].each { it.close unless it.closed? }
      end
    end

    # Stops the command and everything it started, gracefully first.
    #
    # @param waiter [Process::Waiter] thread waiting on the process group leader
    # @return [void]
    #: (Process::Waiter waiter) -> void
    private def terminate(waiter)
      Process.kill('TERM', -waiter.pid)
      Process.kill('KILL', -waiter.pid) unless waiter.join(KILL_GRACE)
    rescue Errno::ESRCH
      # Already gone.
      nil
    end

    # @param status [Process::Status] exit status
    # @return [String] how the command ended
    #: (Process::Status status) -> String
    private def describe(status)
      status.signaled? ? "was killed by signal #{status.termsig}" : "exited with #{status.exitstatus}"
    end
  end
end

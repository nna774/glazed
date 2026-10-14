# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'open3'
require 'glazed'

module Glazed
  # Runs a command line with /bin/sh -c, or a program with its arguments
  # without a shell, feeding stdin and capturing stdout.
  #
  # @example
  #   Glazed::ShellCommand.new(run: 'sort', env: {}, stdin: "b\na\n", timeout: 10).call #=> "a\nb\n"
  #   Glazed::ShellCommand.new(run: %w[sort -r], env: {}, stdin: "a\nb\n", timeout: 10).call #=> "b\na\n"
  class ShellCommand
    # Raised when the command exits non-zero or is killed by a signal.
    class Failed < Glazed::Error; end

    # Bytes of stderr kept in error messages.
    STDERR_TAIL = 1000 #: Integer
    # Seconds between SIGTERM and SIGKILL when the command overruns.
    KILL_GRACE = 5 #: Integer

    # Picks what to run from settings holding a `run` command line and a
    # `command` argument list, of which one is set.
    #
    # @param run [String] command line for /bin/sh -c
    # @param command [Enumerable<String>] program and its arguments
    # @return [String, Array<String>] command, when set, or the command line
    #: (String run, Enumerable[String] command) -> (String | Array[String])
    def self.run_of(run, command) = command.none? ? run : command.to_a

    # @param run [String, Array<String>] command line for /bin/sh -c, or program and its arguments
    # @param env [Hash{String => String}] environment added to the inherited one
    # @param stdin [String] data written to stdin
    # @param timeout [Numeric] seconds before the command is killed
    #: (run: String | Array[String], env: Hash[String, String], stdin: String, timeout: Numeric) -> void
    def initialize(run:, env:, stdin:, timeout:)
      @run = run #: String | Array[String]
      @env = env #: Hash[String, String]
      @stdin = stdin #: String
      @timeout = timeout #: Numeric
    end

    # Runs the command to completion.
    #
    # @return [String] stdout
    # @raise [Failed] when the command cannot start, exits non-zero or is killed by a signal
    # @raise [TimeoutError] when the command does not finish in time; its process group is killed
    #: () -> String
    def call
      stdin, stdout, stderr, waiter = spawn
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

    # @return [Array(IO, IO, IO, Process::Waiter)] stdin, stdout, stderr and the waiter
    # @raise [Failed] when the program cannot be executed
    #: () -> [IO, IO, IO, Process::Waiter]
    private def spawn
      # Sorbet cannot check a splat against popen3's keyword options (7019).
      open3 = Open3 #: untyped
      open3.popen3(@env, *argv, pgroup: true)
    rescue SystemCallError => e
      raise Failed, "#{@run.inspect} could not start: #{e.message}"
    end

    # @return [Array] arguments for Open3.popen3
    #: () -> Array[String | [String, String]]
    private def argv
      run = @run
      return ['/bin/sh', '-c', run] if run.is_a?(String)

      program, *args = run
      raise ArgumentError, 'empty command' unless program

      # A lone string would be run by a shell, so the program goes as [path, argv0].
      [[program, program], *args]
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

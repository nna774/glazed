# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/command_result'
require 'glazed/dialect/actions'
require 'glazed/dialect/interaction'
require 'glazed/transports/base'

module Glazed
  # Interactive command-line session over a transport, driven by a prompt
  # pattern, data filters and interactions.
  #
  # Received data is kept as bytes (ASCII-8BIT), so a character split across
  # reads cannot break matching. It is filtered fragment by fragment, appended to {#buffer}, and
  # then offered to each interaction. Text up to the end of a match is consumed
  # by {#expect} and {#command}.
  #
  # @example
  #   session = Glazed::CliSession.new(transport:, prompt: /^\S+#\s?$/)
  #   session.command('show version').output
  class CliSession
    # Default seconds to wait for expected output.
    DEFAULT_TIMEOUT = 60 #: Integer
    # Longest single wait on the transport, so a deadline is checked regularly.
    READ_SLICE = 1.0 #: Float

    # @param transport [Transports::Base] open transport
    # @param prompt [Regexp] pattern of the command prompt
    # @param data_filters [Array<Proc>] filters applied to each received fragment, in order
    # @param interactions [Array<Dialect::Interaction>] responders to patterns in the buffer
    # @param exec [Boolean] run {#command} through {Transports::Base#exec} when supported
    # @param timeout [Numeric] default seconds to wait for expected output
    # @param progress [Proc] receives a message whenever the session starts waiting for the device
    #: (transport: Transports::Base, prompt: Regexp, ?data_filters: Array[Dialect::data_filter], ?interactions: Array[Dialect::Interaction], ?exec: bool, ?timeout: Numeric, ?progress: ^(String) -> void) -> void
    def initialize(transport:, prompt:, data_filters: [], interactions: [], exec: false, timeout: DEFAULT_TIMEOUT, progress: ->(_message) {})
      @transport = transport #: Transports::Base
      @prompt = prompt #: Regexp
      @data_filters = data_filters #: Array[Dialect::data_filter]
      @interactions = interactions #: Array[Dialect::Interaction]
      @exec = exec #: bool
      @timeout = timeout #: Numeric
      @progress = progress #: ^(String) -> void
      @buffer = String.new(encoding: Encoding::BINARY) #: String
    end

    # @return [Transports::Base] underlying transport
    #: Transports::Base
    attr_reader :transport
    # @return [Regexp] pattern of the command prompt
    #: Regexp
    attr_reader :prompt
    # @return [Numeric] default seconds to wait for expected output
    #: Numeric
    attr_reader :timeout
    # @return [String] received text not yet consumed
    #: String
    attr_reader :buffer

    # Sends raw data.
    #
    # @param data [String] bytes to send, including any newline
    # @return [void]
    #: (String data) -> void
    def write(data)
      transport.write(data)
    end

    # Waits until a pattern matches the buffer, then consumes the buffer up to
    # the end of the match.
    #
    # @param patterns [Array<Regexp>] patterns tried in order
    # @param timeout [Numeric] seconds to wait
    # @return [MatchData] the first match
    # @raise [TimeoutError] when nothing matches in time
    # @raise [ConnectionClosed] when the device closes the connection first
    #: (*Regexp patterns, ?timeout: Numeric) -> MatchData
    def expect(*patterns, timeout: self.timeout)
      description = patterns.map { it == prompt ? 'prompt' : it.inspect }.join(' or ')
      match = wait_until(description, timeout:) { patterns.lazy.filter_map { it.match(buffer) }.first }
      consume(match)
      match
    end

    # Runs a command and waits for the prompt.
    #
    # @param line [String] command line, without newline
    # @param timeout [Numeric] seconds to wait for the prompt
    # @return [CommandResult] output without the echoed command and the prompt
    # @raise [TimeoutError] when the prompt does not appear in time
    # @raise [ConnectionClosed] when the device closes the connection first
    #: (String line, ?timeout: Numeric) -> CommandResult
    def command(line, timeout: self.timeout)
      if @exec && transport.exec?
        @progress.call("waiting for output of #{line.inspect}")
        return CommandResult.new(command: line, output: filter(transport.exec(line, timeout:).b))
      end

      discard
      write("#{line}\n")
      # The prompt is searched only after the echoed line, so a prompt left over
      # from before the command cannot end it early.
      match = wait_until("prompt after #{line.inspect}", timeout:) do
        echo_end = buffer.index("\n")
        prompt.match(buffer, echo_end + 1) if echo_end
      end
      output_start = (buffer.index("\n") || -1) + 1
      output = buffer[output_start...match.begin(0)] || String.new(encoding: Encoding::BINARY)
      consume(match)
      CommandResult.new(command: line, output:)
    end

    # Clears the buffer.
    #
    # @return [String] the discarded text
    #: () -> String
    def discard
      discarded = @buffer
      @buffer = String.new(encoding: Encoding::BINARY)
      discarded
    end

    # @param description [String] what is awaited, for error messages
    # @param timeout [Numeric] seconds to wait
    # @yieldreturn [MatchData, nil] match against the current buffer, or nil to keep waiting
    # @return [MatchData] the first non-nil match
    # @raise [TimeoutError] when nothing matches in time
    # @raise [ConnectionClosed] when the device closes the connection first
    #: (String description, timeout: Numeric) { () -> MatchData? } -> MatchData
    private def wait_until(description, timeout:, &matcher)
      @progress.call("waiting for #{description}")
      deadline = now + timeout.to_f
      loop do
        match = matcher.call
        return match if match

        remaining = deadline - now
        raise TimeoutError, "timed out after #{timeout}s waiting for #{description}; buffer tail: #{(buffer[-200..] || buffer).dump}" unless remaining.positive?

        data = transport.read(timeout: [remaining, READ_SLICE].min)
        raise ConnectionClosed, "connection closed while waiting for #{description}" if data.nil?

        feed(data) unless data.empty?
      end
    end

    # @param data [String] received fragment
    # @return [void]
    #: (String data) -> void
    private def feed(data)
      @buffer << filter(data.b).b
      @interactions.each do |interaction|
        match = interaction.pattern.match(@buffer)
        @buffer = Dialect::Actions.apply(@buffer, interaction.responder.call(self, @buffer.dup, match)) if match
      end
    end

    # @param data [String] received text
    # @return [String] text after every data filter
    #: (String data) -> String
    private def filter(data)
      @data_filters.inject(data.dup) { |result, data_filter| data_filter.call(result) }
    end

    # @param match [MatchData] match against the buffer
    # @return [void]
    #: (MatchData match) -> void
    private def consume(match)
      @buffer = buffer[match.end(0)..] || String.new(encoding: Encoding::BINARY)
    end

    # @return [Float] monotonic clock reading in seconds
    #: () -> Float
    private def now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
  end
end

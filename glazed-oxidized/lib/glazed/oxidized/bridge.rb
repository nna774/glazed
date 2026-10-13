# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/cli_session'
require 'glazed/dialect/run'
require 'glazed/oxidized/errors'
require 'glazed/oxidized/model_box'
require 'glazed/oxidized/node_view'

module Glazed
  module Oxidized
    # Connects one CLI session to an instance of an Oxidized model, so that the
    # model and its inputs reach the device through glazed.
    #
    # A bridge is created on first use for a session, which may be an
    # interaction during login, and is attached to the run after login.
    class Bridge
      @registry = ObjectSpace::WeakKeyMap.new #: ObjectSpace::WeakKeyMap
      @registry_lock = Mutex.new #: Thread::Mutex

      # Finds or creates the bridge of a session.
      #
      # @param session [CliSession] session to the device
      # @param box [ModelBox] model the session runs
      # @return [Bridge] the session's bridge
      #: (CliSession session, ModelBox box) -> Bridge
      def self.for(session, box)
        @registry_lock.synchronize { @registry[session] ||= new(session:, box:) }
      end

      # @param session [CliSession] session to the device
      # @param box [ModelBox] model the session runs
      #: (session: CliSession, box: ModelBox) -> void
      def initialize(session:, box:)
        @session = session #: CliSession
        @run = nil #: Dialect::Run?
        @model = box.new_model #: untyped
        @model.input = box.new_generic_input.glazed_attach(self, nil)
      end

      # @return [CliSession] session to the device
      #: CliSession
      attr_reader :session
      # @return [Object] the model instance
      #: untyped
      attr_reader :model

      # Binds the model and the input configured for the transport to a run.
      #
      # @param run [Dialect::Run] the run in progress
      # @param input [Object] the box's input, with the model's cfg blocks evaluated
      # @return [void]
      #: (Dialect::Run run, untyped input) -> void
      def attach(run, input)
        @run = run
        node = NodeView.new(node: run.node, prompt: session.prompt, secrets: run.secrets)
        input.glazed_attach(self, node)
        model.node = node
        model.input = input
      end

      # Collects the configuration through the model.
      #
      # @return [String] the configuration
      # @raise [Error] when a command of the model returned no output
      #: () -> String
      def get
        model.glazed_get or raise Error, 'the Oxidized model returned no configuration'
      end

      # Applies one of the model's expect blocks to the session buffer.
      #
      # @param index [Integer] position of the block among the model's expects
      # @param buffer [String] copy of the session buffer
      # @return [String] the new buffer, as bytes
      #: (Integer index, String buffer) -> String
      def apply_expect(index, buffer) = model.glazed_expect(index, buffer).to_s.b

      # Sends raw data.
      #
      # @param data [String] data to send
      # @return [void]
      #: (String data) -> void
      def write(data)
        session.write(data)
      end

      # @return [String] data received but not consumed yet
      #: () -> String
      def output = session.buffer.dup

      # Waits for one of the patterns, consuming the buffer up to the match.
      #
      # @param patterns [Array<Regexp>] patterns
      # @return [Regexp] the pattern that matched
      # @raise [TimeoutError] when nothing matches in time
      #: (Array[Regexp] patterns) -> Regexp
      def expect(patterns)
        cli = session #: as untyped
        cli.expect(*patterns).regexp
      end

      # Runs a command the way Oxidized inputs do: on a shell, the output
      # includes the echoed command and the prompt, which models cut.
      #
      # @param line [String] command line
      # @param expect [Regexp, Array<Regexp>, nil] patterns ending the output; nil only sends the line
      # @param exec [Boolean] run on an exec channel when the transport supports it
      # @return [String] the output, in UTF-8
      # @raise [TimeoutError] when nothing matches in time
      # @raise [InvalidEncoding] when the output is not valid UTF-8
      #: (String line, Regexp | Array[Regexp] | nil expect, exec: bool) -> String
      def cmd(line, expect, exec:)
        unless expect
          write("#{line}\n")
          return +''
        end

        transport = session.transport
        raw = if exec && transport.exec?
          transport.exec(line, timeout: session.timeout).b
        else
          cli = session #: as untyped
          cli.discard
          write("#{line}\n")
          match = cli.expect(*Array(expect)) #: MatchData
          match.pre_match + match[0].to_s
        end
        normalize(line, raw)
      end

      # @param line [String] command line
      # @param raw [String] output as bytes
      # @return [String] the output after the dialect's output filters, in UTF-8
      # @raise [InvalidEncoding] when the output is not valid UTF-8
      #: (String line, String raw) -> String
      private def normalize(line, raw)
        filters = @run&.dialect&.output_filters || []
        output = filters.inject(raw) { |text, output_filter| output_filter.call(text) }.dup.force_encoding(Encoding::UTF_8)
        raise InvalidEncoding, "output of #{line.inspect} is not valid UTF-8" unless output.valid_encoding?

        output
      end
    end
  end
end

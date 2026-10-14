# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'time'
require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/runner'
require 'glazed/validation'

module Glazed
  module Aws
    # Reads {Proto::V1::Signal}s from the input of a Step Functions execution,
    # in the shapes its triggers deliver:
    #
    # - an EventBridge event, from a rule targeting the state machine, whose `detail` is a Signal
    # - an array of SQS messages, from an EventBridge Pipe, whose bodies are Signals or EventBridge events
    # - `{"signals": [...]}`, from EventBridge Scheduler or a manual StartExecution
    #
    # A Signal lacking `source` or `received_at` takes the event's source and
    # time. Entries that do not decode or validate are reported and skipped,
    # so one bad message does not hold back the others.
    module SignalEvents
      # @param input [Object] the execution input, decoded from JSON
      # @param listener [Proc] receives an event for each skipped entry
      # @return [Array<Proto::V1::Signal>] the signals
      #: (untyped input, ?listener: Runner::listener) -> Array[Proto::V1::Signal]
      def self.extract(input, listener: ->(_event) {})
        case input
        when Array then input.flat_map { from_sqs_message(it, listener:) }
        when Hash
          if input.key?('detail-type') then from_event(input, listener:)
          elsif input.key?('signals') then Array(input['signals']).filter_map { decode(it, listener:) }
          else []
          end
        else []
        end
      end

      # @param message [Object] an SQS message as an EventBridge Pipe delivers it
      # @param listener [Proc] receives an event when the message is skipped
      # @return [Array<Proto::V1::Signal>] the signals in its body
      #: (untyped message, listener: Runner::listener) -> Array[Proto::V1::Signal]
      private_class_method def self.from_sqs_message(message, listener:)
        body = message.is_a?(Hash) ? message['body'] : nil
        unless body.is_a?(String)
          skip(listener, 'SQS message without a body')
          return []
        end

        begin
          document = JSON.parse(body) #: untyped
        rescue JSON::ParserError => e
          skip(listener, "SQS message #{message['messageId']}: #{e.message}")
          return []
        end
        return from_event(document, listener:) if document.is_a?(Hash) && document.key?('detail-type')

        sent = message.dig('attributes', 'SentTimestamp')
        received_at = (Time.at(Rational(sent.to_i, 1000)).utc.iso8601(3) if sent) #: String?
        [decode(document, listener:, received_at:)].compact
      end

      # @param event [Hash] an EventBridge event
      # @param listener [Proc] receives an event when the event is skipped
      # @return [Array<Proto::V1::Signal>] the signal in its detail
      #: (Hash[String, untyped] event, listener: Runner::listener) -> Array[Proto::V1::Signal]
      private_class_method def self.from_event(event, listener:)
        [decode(event['detail'], listener:, source: event['source'], received_at: event['time'])].compact
      end

      # @param document [Object] a Signal as ProtoJSON, decoded from JSON
      # @param listener [Proc] receives an event when the document is skipped
      # @param source [String, nil] source when the document has none
      # @param received_at [String, nil] RFC 3339 reception time when the document has none
      # @return [Proto::V1::Signal, nil] the signal; nil when it is invalid
      #: (untyped document, listener: Runner::listener, ?source: String?, ?received_at: String?) -> Proto::V1::Signal?
      private_class_method def self.decode(document, listener:, source: nil, received_at: nil)
        unless document.is_a?(Hash)
          skip(listener, "signal is not an object: #{JSON.generate(document)}")
          return
        end

        defaults = {'source' => source, 'received_at' => received_at}.compact
        signal = ProtoJson.load(Proto::V1::Signal, JSON.generate(defaults.merge(document)))
        Validation.validate!(signal)
        signal
      rescue Google::Protobuf::ParseError, InvalidMessage => e
        skip(listener, "invalid signal #{JSON.generate(document)}: #{e.message}")
        nil
      end

      # @param listener [Proc] receives the event
      # @param message [String] why an entry is skipped
      # @return [void]
      #: (Runner::listener listener, String message) -> void
      private_class_method def self.skip(listener, message)
        listener.call({level: 'error', message: "signal skipped: #{message}"})
      end
    end
  end
end

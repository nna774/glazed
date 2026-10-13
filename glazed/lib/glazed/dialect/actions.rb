# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialect'

module Glazed
  module Dialect
    # Edits that interactions and runbook steps apply to a text buffer.
    #
    # A String is shorthand for {Append} and nil does nothing.
    module Actions
      # Action applying content to a buffer.
      class Content
        # @param content [String] text the action carries
        #: (content: String) -> void
        def initialize(content:)
          @content = content.dup.freeze #: String
        end

        # @return [String] text the action carries
        #: String
        attr_reader :content

        # @param other [Object] object to compare
        # @return [Boolean] whether other is the same action with the same content
        #: (untyped other) -> bool
        def ==(other) = other.class == self.class && other.content == content

        alias eql? ==

        # @return [Integer] hash consistent with {#==}
        #: () -> Integer
        def hash = [self.class, content].hash
      end

      # Appends content to the buffer.
      class Append < Content; end

      # Replaces the whole buffer with content.
      class Replace < Content; end

      # Applies several actions in order.
      class Multi
        # @param actions [Array<Append, Replace, Multi, String, nil>] actions, flattened and normalised
        #: (*Actions::action? actions) -> void
        def initialize(*actions)
          @actions = actions.flat_map { Multi.normalize(it) }.freeze #: Array[Append | Replace]
        end

        # @return [Array<Append, Replace>] flattened actions
        #: Array[Append | Replace]
        attr_reader :actions

        # @param action [Append, Replace, Multi, String, nil] action to normalise
        # @return [Array<Append, Replace>] equivalent plain actions
        #: (Actions::action? action) -> Array[Append | Replace]
        def self.normalize(action)
          case action
          when nil then []
          when String then [Append.new(content: action)]
          when Multi then action.actions
          else [action]
          end
        end

        # @param other [Object] object to compare
        # @return [Boolean] whether other holds the same actions
        #: (untyped other) -> bool
        def ==(other) = other.is_a?(Multi) ? other.actions == actions : false
      end

      #: type action = Append | Replace | Multi | String

      # Applies an action to a buffer.
      #
      # @param buffer [String] text to edit
      # @param action [Append, Replace, Multi, String, nil] action to apply
      # @return [String] the edited text, a new string
      # @example
      #   Actions.apply("a", Actions::Append.new(content: "b")) #=> "ab"
      #: (String buffer, Actions::action? action) -> String
      def self.apply(buffer, action)
        Multi.normalize(action).inject(buffer.dup) do |result, step|
          case step
          when Append then result << step.content
          when Replace then step.content.dup
          else step #: absurd
          end
        end
      end
    end
  end
end

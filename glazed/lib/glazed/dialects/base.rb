# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialect_runbook'

module Glazed
  module Dialects
    module Base
      def self.included(klass)
        klass.extend(BuilderDsl)
      end

      def definition
        self.class
      end

      Interaction = Data.define(:pattern, :responder)
      SensitivePattern = Data.define(:pattern, :determiner)
      CommunicatorConfigurator = Data.define(:kinds, :block)

      module BuilderDsl
        def prompt(other)
          raise TypeError, "prompt must be a Regexp" unless other.is_a?(Regexp)
          @prompt = other
          nil
        end

        def filter_data(&filter)
          (@data_filters ||= []) << filter
          nil
        end

        def interact(pattern, &responder)
          (@interacts ||= []) << Interaction.new(pattern:, responder:)
          nil
        end

        def sensitive_pattern(pattern, &determiner)
          (@sensitive_patterns ||= []) << SensitivePattern.new(pattern:, determiner:)
          nil
        end

        def communication(*communicator_kinds, &configure)
          (@communications ||= []) << CommunicatorConfigurator.new(kinds: communicator_kinds, block: configure)
          nil
        end

        def runbook(operation, &content)
          builder = (@runbooks ||= {})[operation] ||= DialectRunbook.builder
          builder.instance_eval(&content)
          nil
        end

        def prompt_pattern = @prompt
        attr_reader :data_filters
        attr_reader :interacts
        attr_reader :sensitive_patterns
        attr_reader :communications
        attr_reader :runbooks
      end

      module Actions
        Replace = Data.define(:content)
        Append = Data.define(:content)
        Multi = Data.define(:actions) do
          def initialize(*actions)
            actions = actions.flat_map do |a|
              if a.is_a?(self.class)
                a.actions
              else
                a
              end
            end
            super(actions:)
          end

          def self.maybe(maybe_multi)
            case maybe_multi
            when self
              maybe_multi
            else
              new(maybe_multi)
            end
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

module Glazed
  class DialectRunbook
    def initialize(operations)
      @operations = operations
    end

    def self.builder
      Builder.new
    end

    attr_reader :operations

    Op = Data.define(:description, :block)

    class Builder
      def initialize
        @operations = []
      end

      attr_reader :operations

      def to_runbook
        DialectRunbook.new(operations.dup.freeze)
      end

      def command(line, &callback)
        raw(line) do |comm, &action|
          # TODO: raise TypeError, "command is only available with Cli"
          res = comm.command(line)
          action.call(callback.call(res))
        end
      end

      def raw(description = '', &callback)
        @operations << Op.new(description:, block: callback)
        nil
      end
    end
  end
end

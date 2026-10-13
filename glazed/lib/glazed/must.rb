# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

module Glazed
  # Runtime counterpart of Sorbet's T.must for a value the type checker cannot
  # prove present. The reason names the invariant that makes it so.
  module Must
    # Raised when an asserted invariant does not hold.
    class Violation < StandardError; end

    # Returns the value, or raises with the reason when it is nil.
    #
    # @param value [Object, nil] value expected to be present
    # @yieldreturn [String] the invariant that makes the value present
    # @return [Object] the value
    # @raise [Violation] when the value is nil
    #: [T] (T? value) { () -> String } -> T
    def self.because(value, &_block)
      case value
      when nil then raise Violation, yield
      else value
      end
    end

    # Returns the value, or raises when it is nil.
    #
    # @param value [Object, nil] value expected to be present
    # @return [Object] the value
    # @raise [Violation] when the value is nil
    #: [T] (T? value) -> T
    def self.expect(value)
      case value
      when nil then raise Violation, 'expected a value, got nil'
      else value
      end
    end

    # Returns the value narrowed to the class, or raises.
    #
    # @param value [Object] value to narrow
    # @param klass [Class] expected class
    # @return [Object] the value
    # @raise [Violation] when the value is not a klass
    #: [T] (untyped value, Class[T] klass) -> T
    def self.be_a(value, klass)
      case value
      when klass then value
      else raise Violation, "expected #{klass}, got #{value.class}"
      end
    end
  end
end

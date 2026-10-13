# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/must'
require 'glazed/oxidized/errors'

module Glazed
  module Oxidized
    # An Oxidized model file loaded into its own Ruby::Box, together with the
    # emulated Oxidized API it builds on, so that its top-level classes,
    # monkey patches and globals stay out of the main box.
    #
    # @example
    #   box = Glazed::Oxidized::ModelBox.new(name: 'ios', path: '/path/to/model/ios.rb')
    #   box.model_class.prompt #=> /^([\w.@()-]+#\s?)$/
    class ModelBox
      # File loaded into each box before the model.
      PRELUDE = File.expand_path('prelude.rb', __dir__) #: String

      # Input class names inside the box, by glazed transport name.
      INPUTS = {ssh: :SSH, telnet: :Telnet}.freeze #: Hash[Symbol, Symbol]

      # @param name [String] model name, the file name without extension
      # @param path [String] path of the model file
      # @raise [ModelNotFound] when the file defines no model class by that name
      # @raise [UnavailableError] when Ruby::Box is not enabled
      #: (name: String, path: String) -> void
      def initialize(name:, path:)
        ModelBox.ensure_enabled!
        @name = name #: String
        @path = path #: String
        @box = Ruby::Box.new #: Ruby::Box[top]
        @box.require(PRELUDE)
        @box.require(path)
        @model_class = find_model_class #: untyped
      end

      # @return [String] model name
      #: String
      attr_reader :name
      # @return [String] path of the model file
      #: String
      attr_reader :path
      # @return [Class] the model class, a subclass of the box's Oxidized::Model
      #: untyped
      attr_reader :model_class

      # @raise [UnavailableError] when Ruby::Box is not enabled
      # @return [void]
      #: () -> void
      def self.ensure_enabled!
        return if defined?(Ruby::Box) && Ruby::Box.enabled?

        raise UnavailableError, 'glazed-oxidized loads models into Ruby::Box; run Ruby 4.0+ with RUBY_BOX=1'
      end

      # @return [Object] a new instance of the model
      #: () -> untyped
      def new_model = model_class.new

      # @return [Object] a new instance of the box's Oxidized::Input
      #: () -> untyped
      def new_generic_input = oxidized.const_get(:Input).new

      # Builds an input with the model's cfg blocks for a transport evaluated on it.
      #
      # @param kind [Symbol] glazed transport name
      # @return [Object, nil] the input, or nil when the model has no cfg block for the transport
      #: (Symbol kind) -> untyped
      def configured_input(kind)
        class_name = INPUTS[kind] or return nil
        blocks = model_class.cfgs.fetch(kind.to_s, [])
        return nil if blocks.empty?

        input = oxidized.const_get(class_name).new
        blocks.each { input.instance_exec(&it) }
        input
      end

      # @return [Module] the box's Oxidized module
      #: () -> Module[untyped]
      private def oxidized = Must.be_a(@box.const_get(:Oxidized), Module)

      # Finds the class named after the file, ignoring case, as Oxidized does.
      #
      # @return [Class] the model class
      # @raise [ModelNotFound] when there is none
      #: () -> untyped
      private def find_model_class
        constant = @box.constants.find { it.to_s.casecmp?(name) }
        klass = constant && @box.const_get(constant)
        unless klass.is_a?(Class) && klass < oxidized.const_get(:Model)
          raise ModelNotFound, "#{path} defines no Oxidized model named #{name}"
        end

        klass
      end
    end
  end
end

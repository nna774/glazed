# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/base'
require 'glazed/oxidized/errors'
require 'glazed/oxidized/bridge'
require 'glazed/oxidized/model_box'

module Glazed
  module Oxidized
    # Base class of dialects that run an Oxidized model.
    #
    # The model's prompt, comment prefix, expect blocks and login prompts map
    # to dialect declarations. Commands, pre and post blocks, and cfg blocks
    # run inside the model's box, as one :get runbook step. The substitutions
    # of the model's `cmd :secret` blocks become sensitive patterns, and the
    # blocks themselves run when the node param "remove_secret" is "true".
    class ModelDialect < Dialects::Base
      # Prompt Oxidized uses for models that declare none.
      DEFAULT_PROMPT = /^([\w.@-]+[#>]\s?)$/ #: Regexp

      @model_box = nil #: ModelBox?
      @unredactable = nil #: String?

      class << self
        # Builds a dialect class for a loaded model.
        #
        # @param box [ModelBox] the loaded model
        # @return [Class<ModelDialect>] the dialect
        # @example
        #   Glazed::Oxidized::ModelDialect.build(Glazed::Oxidized::ModelBox.new(name: 'ios', path:))
        #: (ModelBox box) -> singleton(ModelDialect)
        def build(box)
          dialect = Class.new(self)
          dialect.declare(box)
          dialect
        end

        # @return [ModelBox] the model this dialect runs
        # @raise [Must::Violation] on {ModelDialect} itself
        #: () -> ModelBox
        def model_box = Must.expect(@model_box)

        # @return [Array<Glazed::Dialect::SensitivePattern>] patterns from the model's `cmd :secret` blocks
        # @raise [UnredactableModel] when the blocks cannot be turned into patterns
        #: () -> Array[Glazed::Dialect::SensitivePattern]
        def sensitive_patterns
          reason = @unredactable
          raise UnredactableModel, reason if reason

          super
        end

        # @param box [ModelBox] the model to run
        # @return [void]
        #: (ModelBox box) -> void
        protected def declare(box)
          @model_box = box
          model = box.model_class
          prompt(model.prompt || DEFAULT_PROMPT)
          comment_prefix(model.comment)
          model.expects.each_with_index do |(pattern, _block), index|
            interact(pattern) do |cli, buffer, _match|
              Glazed::Dialect::Actions::Replace.new(content: Bridge.for(cli, box).apply_expect(index, buffer))
            end
          end
          declare_secrets(box)
          ModelBox::INPUTS.each_key do |kind|
            communication(kind) { |config| configure(config, kind) }
          end
          runbook(:get) do |book|
            book.raw("oxidized model #{box.name}") { |run| run.emit(Bridge.for(run.cli, box).get) }
          end
        end

        # Declares a sensitive pattern for each substitution of the model's
        # `cmd :secret` blocks. Blocks that do anything else make
        # {sensitive_patterns} raise, so redaction fails rather than leaks.
        #
        # @param box [ModelBox] the loaded model
        # @return [void]
        #: (ModelBox box) -> void
        private def declare_secrets(box)
          box.secret_substitutions.each do |substitution|
            sensitive_pattern(substitution.pattern) { substitution.offsets(it) }
          end
        rescue UnredactableModel => e
          @unredactable = e.message
        end

        # Applies the model's cfg blocks for a transport to a communication config.
        #
        # @param config [Glazed::Dialect::CommunicationConfig] config to fill
        # @param kind [Symbol] transport name
        # @return [void]
        #: (Glazed::Dialect::CommunicationConfig config, Symbol kind) -> void
        private def configure(config, kind)
          box = model_box
          input = box.configured_input(kind)
          unless input
            config.post_login { raise UnsupportedTransport, "Oxidized model #{box.name} has no cfg block for #{kind}" }
            return
          end

          config.username_prompt = input.glazed_username_prompt
          config.password_prompt = input.glazed_password_prompt
          config.exec = input.glazed_exec?
          config.post_login do |run|
            Bridge.for(run.cli, box).attach(run, input)
            input.connect_cli
          end
          config.pre_logout { input.disconnect_cli }
        end
      end
    end
  end
end

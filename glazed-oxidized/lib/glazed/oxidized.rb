# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/dialects'
require 'glazed/must'
require 'glazed/oxidized/errors'
require 'glazed/oxidized/model_box'
require 'glazed/oxidized/model_dialect'
require 'glazed/oxidized/version'

module Glazed
  # Runs Oxidized model files as glazed dialects. A node whose dialect is
  # "oxidized_<model>" runs the model file `<model>.rb` found in {model_paths}.
  #
  # Each model is loaded into its own Ruby::Box, which needs RUBY_BOX=1 in the
  # environment of the Ruby process.
  #
  # @example
  #   require 'glazed/oxidized'
  #   Glazed::Dialects.find('oxidized_aireos') #=> Glazed::Dialects::OxidizedAireos
  module Oxidized
    # Prefix of dialect names that run an Oxidized model.
    DIALECT_PREFIX = 'oxidized_' #: String

    @model_paths = nil #: Array[String]?
    @lock = Mutex.new #: Thread::Mutex

    class << self
      # Directories searched for model files, in order. Defaults to Oxidized's
      # own order: the model directory under $OXIDIZED_HOME (or
      # ~/.config/oxidized), then the models of the installed oxidized gem.
      #
      # @return [Array<String>] directories, which callers may change
      #: () -> Array[String]
      def model_paths
        @model_paths ||= default_model_paths
      end

      # @param paths [Array<String>] directories searched for model files
      # @return [void]
      #: (Array[String] paths) -> void
      def model_paths=(paths)
        @model_paths = paths
      end

      # @param name [String] model name, such as "ios"
      # @return [String, nil] path of the first model file by that name in {model_paths}
      #: (String name) -> String?
      def model_path(name)
        return nil unless name.match?(/\A[a-z0-9_]+\z/)

        model_paths.map { File.join(it, "#{name}.rb") }.find { File.file?(it) }
      end

      # Builds the dialect running a model and registers it under
      # {Dialects}, so later lookups find it without loading the model again.
      #
      # @param name [String] model name, such as "ios"
      # @return [Class<ModelDialect>, nil] the dialect, or nil when no model file has the name
      # @raise [UnavailableError] when Ruby::Box is not enabled
      # @raise [ModelNotFound] when the file defines no model class by its name
      #: (String name) -> singleton(ModelDialect)?
      def dialect(name)
        constant_name = "#{DIALECT_PREFIX}#{name}".split('_').map(&:capitalize).join
        @lock.synchronize do
          if Dialects.const_defined?(constant_name, false)
            return Must.be_a(Dialects.const_get(constant_name, false), Class) #: as singleton(ModelDialect)
          end

          path = model_path(name) or return nil
          dialect = ModelDialect.build(ModelBox.new(name:, path:))
          Dialects.const_set(constant_name, dialect)
          dialect
        end
      end

      # @return [Array<String>] Oxidized's model directories
      #: () -> Array[String]
      private def default_model_paths
        home = ENV.fetch('OXIDIZED_HOME') { File.join(Dir.home, '.config', 'oxidized') }
        paths = [File.join(home, 'model')]
        gem = Gem::Specification.find_all_by_name('oxidized').max_by(&:version)
        paths << File.join(gem.gem_dir, 'lib', 'oxidized', 'model') if gem
        paths
      end
    end

    Dialects.add_resolver { |name| dialect(name.delete_prefix(DIALECT_PREFIX)) if name.start_with?(DIALECT_PREFIX) }
  end
end

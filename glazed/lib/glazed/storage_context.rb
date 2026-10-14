# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/secrets_resolver'

module Glazed
  # What storages are built with, besides their own settings.
  class StorageContext
    # @param secrets [SecretsResolver] reads secrets the storages refer to
    #: (?secrets: SecretsResolver) -> void
    def initialize(secrets: SecretsResolver.new)
      @secrets = secrets #: SecretsResolver
    end

    # @return [SecretsResolver] reads secrets the storages refer to
    #: SecretsResolver
    attr_reader :secrets
  end
end

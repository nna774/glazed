# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'

module Glazed
  module Oxidized
    # Base class for errors raised by glazed-oxidized.
    class Error < Glazed::Error; end
    # Raised when Ruby::Box is unavailable.
    class UnavailableError < Error; end
    # Raised when a model file defines no model class by its name.
    class ModelNotFound < Error; end
    # Raised when a model has no cfg block for the transport of a node.
    class UnsupportedTransport < Error; end
    # Raised when a model's `cmd :secret` blocks cannot be turned into sensitive patterns.
    class UnredactableModel < Error; end
  end
end

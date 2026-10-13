# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require_relative 'glazed/version'

# Network device configuration scraper.
module Glazed
  # Base class for errors raised by glazed.
  class Error < StandardError; end
  # Raised when a device does not produce expected output in time.
  class TimeoutError < Error; end
  # Raised when a device closes the connection unexpectedly.
  class ConnectionClosed < Error; end
end

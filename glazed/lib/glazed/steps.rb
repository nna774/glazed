# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'

module Glazed
  # Units of work that coordinators run. Each takes and returns protobuf
  # messages, so a coordinator can pass them between processes as ProtoJSON.
  module Steps
  end
end

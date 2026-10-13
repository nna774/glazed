# typed: true
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# tapioca dsl loads no application code outside Rails, so the generated
# messages are required here for its Protobuf compiler to find them.
$LOAD_PATH.unshift(File.expand_path('../../../glazed/lib', __dir__))
require 'glazed/proto'

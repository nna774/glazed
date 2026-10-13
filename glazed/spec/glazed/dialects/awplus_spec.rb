# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/awplus'

RSpec.describe Glazed::Dialects::Awplus do
  it_behaves_like 'a dialect simulation', 'awplus/x230', transport: 'ssh'
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/junos'

RSpec.describe Glazed::Dialects::Junos do
  it_behaves_like 'a dialect simulation', 'junos/srx300_22.4', transport: 'ssh', exec: true
end

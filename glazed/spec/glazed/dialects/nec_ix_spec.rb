# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/nec_ix'

RSpec.describe Glazed::Dialects::NecIx do
  it_behaves_like 'a dialect simulation', 'nec_ix/ix2215', transport: 'ssh'
end

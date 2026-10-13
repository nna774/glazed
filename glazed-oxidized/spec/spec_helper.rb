# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

abort 'glazed-oxidized specs need Ruby::Box; run them with RUBY_BOX=1' unless defined?(Ruby::Box) && Ruby::Box.enabled?

require 'glazed/oxidized'

# The scripted device and simulations of the glazed gem's own specs.
require_relative '../../glazed/spec/support/fake_transport'
require_relative '../../glazed/spec/support/simulation'

FIXTURE_MODELS = File.expand_path('fixtures/model', __dir__)
Glazed::Oxidized.model_paths = [FIXTURE_MODELS]

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

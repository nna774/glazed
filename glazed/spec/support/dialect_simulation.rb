# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/collector'
require 'glazed/redactor'

# Collects a Simulation through the described dialect and compares the result
# with its golden files. GLAZED_UPDATE_GOLDEN=1 rewrites them instead; review the
# diff before committing.
RSpec.shared_examples 'a dialect simulation' do |name, transport:, exec: false, node_secrets: {}|
  let(:simulation) { Simulation.load(name) }
  let(:dialect_name) { name.split('/').first }
  let(:node) do
    Glazed::Proto::V1::Node.new(
      name: 'rt1', dialect: dialect_name, transport:, username: 'admin', password: {value: 'pw'},
      secrets: node_secrets.transform_values { {value: it} },
    )
  end
  let(:device) { exec ? simulation.exec_device : simulation.shell_device }
  let(:collected) { Glazed::Collector.new(node:, timeout: 1).call }
  let(:redacted) { Glazed::Redactor.new(patterns: described_class.sensitive_patterns, mode: :remove).call(collected) }

  before { stub_const("Glazed::Transports::#{transport.split('_').map(&:capitalize).join}", device) }

  it "collects #{name}" do
    simulation.write_expected('collected', collected) if ENV['GLAZED_UPDATE_GOLDEN']
    expect(collected).to eq(simulation.expected('collected'))
  end

  it "redacts #{name}" do
    simulation.write_expected('redacted', redacted) if ENV['GLAZED_UPDATE_GOLDEN']
    expect(redacted).to eq(simulation.expected('redacted'))
  end

  it "leaves no listed secret in redacted #{name}" do
    simulation.secrets.each { expect(redacted).not_to include(it) }
  end
end

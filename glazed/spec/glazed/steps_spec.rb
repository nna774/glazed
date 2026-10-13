# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/steps'

RSpec.describe Glazed::Steps do
  let(:context) { Glazed::Steps::Context.new(storages: {'vault' => instance_double(Glazed::Storages::Base)}) }

  it 'builds a step by its action name' do
    step = described_class.build(Glazed::Proto::V1::Step.new(name: 'f', fetch: {output: 'raw', storage: 'vault'}), context:)
    expect(step).to be_a(Glazed::Steps::Fetch).and(have_attributes(name: 'f'))
  end

  it 'requires a name and an action' do
    expect { described_class.build(Glazed::Proto::V1::Step.new(fetch: {}), context:) }.to raise_error(described_class::InvalidStep, /no name/)
    expect { described_class.build(Glazed::Proto::V1::Step.new(name: 'x'), context:) }.to raise_error(described_class::InvalidStep, /no action/)
  end

  it 'does not treat the step bases as steps' do
    expect { described_class.find('node_step') }.to raise_error(Glazed::Must::Violation)
  end
end

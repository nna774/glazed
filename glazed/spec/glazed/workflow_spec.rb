# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/workflow'

RSpec.describe Glazed::Workflow do
  let(:context) { Glazed::Steps::Context.new(storages: {'s' => instance_double(Glazed::Storages::Base)}) }

  def build(*steps) = described_class.from_proto(Glazed::Proto::V1::Workflow.new(steps:), context:)

  let(:fetch) { {name: 'fetch', fetch: {output: 'raw', storage: 's'}} }
  let(:redact) { {name: 'redact', redact: {input: 'raw', output: 'redacted', storage: 's'}} }
  let(:publish) { {name: 'publish', publish: {input: 'redacted', storage: 's'}} }

  it 'builds steps in order' do
    expect(build(fetch, redact, publish).steps.map(&:name)).to eq(%w[fetch redact publish])
  end

  it 'rejects an input no earlier step produces' do
    expect { build(fetch, publish) }.to raise_error(described_class::Invalid, /publish: no earlier step produces redacted/)
  end

  it 'rejects an artifact produced twice' do
    expect { build(fetch, fetch.merge(name: 'again')) }.to raise_error(described_class::Invalid, /raw is already produced/)
  end

  it 'rejects repeated step names' do
    expect { build(fetch, redact.merge(name: 'fetch')) }.to raise_error(described_class::Invalid, /repeat: fetch/)
  end

  it 'rejects an empty workflow' do
    expect { build }.to raise_error(described_class::Invalid, /no steps/)
  end
end

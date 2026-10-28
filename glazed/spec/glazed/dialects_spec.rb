# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects'

RSpec.describe Glazed::Dialects do
  it 'finds dialects by name' do
    expect(described_class.find('nec_ix')).to eq(Glazed::Dialects::NecIx)
  end

  it 'rejects Base' do
    expect { described_class.find('base') }.to raise_error(Glazed::Must::Violation)
  end

  it 'raises NotFound for unknown names' do
    expect { described_class.find('nonexistent') }.to raise_error(Glazed::Finder::NotFound, /"nonexistent"/)
  end

  %w[aireos aruba_instant awplus edgeos eos ios junos nec_ix routeros].each do |name|
    it "loads #{name} with a get runbook and prompt" do
      dialect = described_class.find(name)
      expect(dialect.runbook_for(:get).steps).not_to be_empty
      expect(dialect.prompt_pattern).to be_a(Regexp)
    end
  end

  describe '.add_resolver' do
    let(:generated) { Class.new(Glazed::Dialects::Base) }
    let(:resolver) { ->(name) { generated if name == 'generated_one' } }

    before { described_class.add_resolver(&resolver) }
    after { described_class.remove_resolver(resolver) }

    it 'resolves names no dialect file answers to' do
      expect(described_class.find(:generated_one)).to eq(generated)
    end

    it 'prefers dialect classes' do
      expect(resolver).not_to receive(:call)
      expect(described_class.find('ios')).to eq(Glazed::Dialects::Ios)
    end

    it 'raises NotFound when no resolver answers' do
      expect { described_class.find('generated_two') }.to raise_error(Glazed::Finder::NotFound)
    end
  end
end

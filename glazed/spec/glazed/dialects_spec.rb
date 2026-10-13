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

  %w[awplus junos nec_ix].each do |name|
    it "loads #{name} with a get runbook and prompt" do
      dialect = described_class.find(name)
      expect(dialect.runbook_for(:get).steps).not_to be_empty
      expect(dialect.prompt_pattern).to be_a(Regexp)
    end
  end
end

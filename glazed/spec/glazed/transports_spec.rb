# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/transports'

RSpec.describe Glazed::Transports do
  it 'finds SSH and Telnet' do
    expect(described_class.find('ssh')).to eq(Glazed::Transports::Ssh)
    expect(described_class.find(:telnet)).to eq(Glazed::Transports::Telnet)
  end

  it 'rejects a non-transport' do
    expect { described_class.find('base') }.to raise_error(Glazed::Must::Violation)
  end

  it 'raises NotFound for an unknown name' do
    expect { described_class.find('carrier_pigeon') }.to raise_error(Glazed::Finder::NotFound)
  end
end

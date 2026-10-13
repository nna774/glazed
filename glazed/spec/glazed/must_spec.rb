# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/must'

RSpec.describe Glazed::Must do
  describe '.because' do
    it 'returns a present value without calling the block' do
      expect(described_class.because(1) { raise 'unreachable' }).to eq(1)
    end

    it 'raises Violation carrying the reason for nil' do
      expect { described_class.because(nil) { 'node is resolved' } }
        .to raise_error(Glazed::Must::Violation, 'node is resolved')
    end
  end

  describe '.expect' do
    it 'returns a present value' do
      expect(described_class.expect(false)).to eq(false)
    end

    it 'raises Violation for nil' do
      expect { described_class.expect(nil) }.to raise_error(Glazed::Must::Violation)
    end
  end

  describe '.be_a' do
    it 'returns a value of the class' do
      expect(described_class.be_a('x', String)).to eq('x')
    end

    it 'raises Violation for another class' do
      expect { described_class.be_a(1, String) }
        .to raise_error(Glazed::Must::Violation, 'expected String, got Integer')
    end
  end
end

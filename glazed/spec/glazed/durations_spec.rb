# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/durations'

RSpec.describe Glazed::Durations do
  describe '.seconds' do
    it 'uses the default when unset or zero' do
      expect(described_class.seconds(nil, 60)).to eq(60.0)
      expect(described_class.seconds(Google::Protobuf::Duration.new, 60)).to eq(60.0)
    end

    it 'reads fractions of a second' do
      expect(described_class.seconds(Google::Protobuf::Duration.new(seconds: 1, nanos: 500_000_000), 60)).to eq(1.5)
    end
  end
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/proto_json'
require 'google/protobuf/descriptor_pb'

RSpec.describe Glazed::ProtoJson do
  let(:klass) { Google::Protobuf::FileOptions }

  it 'dumps proto field names' do
    expect(described_class.dump(klass.new(java_package: 'x'))).to eq('{"java_package":"x"}')
  end

  it 'loads proto field names' do
    expect(described_class.load(klass, '{"java_package":"x"}').java_package).to eq('x')
  end

  it 'rejects unknown fields' do
    expect { described_class.load(klass, '{"nope":1}') }.to raise_error(Google::Protobuf::ParseError)
  end
end

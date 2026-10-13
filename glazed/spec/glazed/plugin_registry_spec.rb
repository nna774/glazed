# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf/wrappers_pb'
require 'glazed/plugin_registry'

RSpec.describe Glazed::PluginRegistry do
  let(:registry) { described_class.new('widget') }
  let(:implementation) { Class.new }

  def pack(value) = Google::Protobuf::Any.pack(Google::Protobuf::StringValue.new(value:))

  it 'resolves packed settings to the registered implementation and unpacked message' do
    registry.register(Google::Protobuf::StringValue, implementation)
    found, settings = registry.resolve(pack('x'))
    expect(found).to eq(implementation)
    expect(settings).to eq(Google::Protobuf::StringValue.new(value: 'x'))
  end

  it 'raises UnknownPlugin naming the type and requires for an unregistered type' do
    expect { registry.resolve(pack('x')) }
      .to raise_error(described_class::UnknownPlugin, /no widget plugin is registered for google.protobuf.StringValue.*requires/)
  end

  it 'forgets an unregistered implementation' do
    registry.register(Google::Protobuf::StringValue, implementation)
    registry.unregister(Google::Protobuf::StringValue)
    expect { registry.resolve(pack('x')) }.to raise_error(described_class::UnknownPlugin)
  end
end

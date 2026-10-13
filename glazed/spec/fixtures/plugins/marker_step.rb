# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# A plugin as a gem would ship it, loaded only through a config's `requires`:
# it defines the settings type glazed_test.v1.Marker and registers a batch
# step for it that records each run's settings text.

require 'google/protobuf'
require 'google/protobuf/descriptor_pb'
require 'glazed/steps'

module GlazedTestPlugin
  file = Google::Protobuf::FileDescriptorProto.new(
    name: 'glazed_test/v1/marker.proto',
    package: 'glazed_test.v1',
    syntax: 'proto3',
    message_type: [{name: 'Marker', field: [{name: 'text', json_name: 'text', number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]}],
  )
  Google::Protobuf::DescriptorPool.generated_pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
  Marker = Google::Protobuf::DescriptorPool.generated_pool.lookup('glazed_test.v1.Marker').msgclass

  # Settings text and node count of each run, in order.
  def self.calls = (@calls ||= [])

  class MarkerStep < Glazed::Steps::BatchStep
    def self.from_proto(name, settings, context:) = new(name:).tap { it.instance_variable_set(:@text, settings.text) }

    def call(batch)
      GlazedTestPlugin.calls << [@text, batch.nodes.size]
      batch
    end
  end

  Glazed::Steps.register(Marker, MarkerStep)
end

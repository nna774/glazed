# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'google/protobuf/wrappers_pb'
require 'glazed/proto_json'
require 'glazed/secrets_resolver'
require 'glazed/sources'
require 'glazed/steps'
require 'glazed/storages'

# Plugins as a config refers to them: ProtoJSON with an "@type" naming the settings message.
RSpec.describe 'plugins' do
  let(:settings_class) { Google::Protobuf::StringValue }
  let(:plugin) { {'@type' => 'type.googleapis.com/google.protobuf.StringValue', 'value' => 'v'} }

  def load(klass, document) = Glazed::ProtoJson.load(klass, JSON.generate(document))

  after { [Glazed::Sources, Glazed::Storages, Glazed::Steps, Glazed::Secrets].each { it::PLUGINS.unregister(settings_class) } }

  it 'builds a registered inventory provider' do
    provider = Class.new(Glazed::Sources::Base) do
      define_singleton_method(:from_proto) { |settings| new.tap { it.instance_variable_set(:@name, settings.value) } }
      define_method(:nodes) { [Glazed::Proto::V1::Node.new(name: @name, dialect: 'ios')] }
    end
    Glazed::Sources.register(settings_class, provider)
    expect(Glazed::Sources.nodes([load(Glazed::Proto::V1::InventorySource, plugin: plugin)]).map(&:name)).to eq(['v'])
  end

  it 'builds a registered storage' do
    storage = Class.new(Glazed::Storages::Base) do
      define_singleton_method(:from_proto) { |settings, context:| new.tap { it.instance_variable_set(:@root, settings.value) } }
      attr_reader :root
    end
    Glazed::Storages.register(settings_class, storage)
    expect(Glazed::Storages.build(load(Glazed::Proto::V1::StorageConfig, plugin: plugin)).root).to eq('v')
  end

  it 'builds a registered step' do
    step = Class.new(Glazed::Steps::BatchStep) { define_singleton_method(:from_proto) { |name, _settings, context:| new(name:) } }
    Glazed::Steps.register(settings_class, step)
    built = Glazed::Steps.build(load(Glazed::Proto::V1::Step, name: 'custom', plugin: plugin), context: Glazed::StepContext.new(storages: {}))
    expect(built).to be_a(step).and(have_attributes(name: 'custom'))
  end

  it 'resolves a secret through a registered source' do
    source = Class.new(Glazed::Secrets::Base) do
      define_singleton_method(:from_proto) { |settings| new.tap { it.instance_variable_set(:@value, "secret-#{settings.value}") } }
      define_method(:value) { @value }
    end
    Glazed::Secrets.register(settings_class, source)
    secret = Glazed::SecretsResolver.new.secret(load(Glazed::Proto::V1::SecretRef, plugin: plugin))
    expect(secret.value).to eq('secret-v')
    expect(secret.inspect).to eq('#<Glazed::Secret plugin:google.protobuf.StringValue>')
  end

  it 'rejects an implementation of the wrong kind' do
    Glazed::Storages.register(settings_class, Class.new(Glazed::Sources::Base))
    expect { Glazed::Storages.build(load(Glazed::Proto::V1::StorageConfig, plugin: plugin)) }
      .to raise_error(Glazed::Must::Violation, /is not a storage/)
  end

  it 'raises UnknownPlugin for an unregistered type' do
    expect { Glazed::Steps.build(load(Glazed::Proto::V1::Step, name: 'x', plugin: plugin), context: Glazed::StepContext.new(storages: {})) }
      .to raise_error(Glazed::PluginRegistry::UnknownPlugin, /no step plugin/)
  end
end

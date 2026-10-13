# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'google/protobuf/wrappers_pb'
require 'glazed/secrets_resolver'

RSpec.describe Glazed::SecretsResolver do
  let(:resolver) { described_class.new }

  def secret(**source) = resolver.secret(Glazed::Proto::V1::SecretRef.new(**source))

  it 'returns a literal value' do
    expect(secret(value: 's3cret').value).to eq('s3cret')
  end

  it 'reads an environment variable' do
    stub_const('ENV', {'GLAZED_TEST_SECRET' => 'from-env'})
    expect(secret(env: 'GLAZED_TEST_SECRET').value).to eq('from-env')
  end

  it 'raises Unavailable for an unset environment variable' do
    stub_const('ENV', {})
    expect { secret(env: 'GLAZED_TEST_SECRET').value }
      .to raise_error(Glazed::Secret::Unavailable, /GLAZED_TEST_SECRET/)
  end

  it 'reads a file without its trailing newline' do
    Dir.mktmpdir do |dir|
      File.write(path = File.join(dir, 'pw'), "from-file\n")
      expect(secret(file: path).value).to eq('from-file')
    end
  end

  it 'raises Unavailable for a missing file' do
    expect { secret(file: '/nonexistent/glazed').value }.to raise_error(Glazed::Secret::Unavailable)
  end

  it 'raises Unavailable without a source' do
    expect { secret.value }.to raise_error(Glazed::Secret::Unavailable)
  end

  it 'keeps a literal value out of inspect' do
    expect(secret(value: 's3cret').inspect).not_to include('s3cret')
  end

  it 'names the environment variable in inspect' do
    expect(secret(env: 'X').to_s).to eq('#<Glazed::Secret env:X>')
  end

  it 'wraps nil as nil' do
    expect(resolver.maybe(nil)).to be_nil
  end

  describe 'plugin sources' do
    let(:settings_class) { Google::Protobuf::StringValue }
    let(:built) { [] }
    let(:ref) do
      Glazed::Proto::V1::SecretRef.new(plugin: Google::Protobuf::Any.pack(Google::Protobuf::StringValue.new(value: 'v')))
    end

    before do
      log = built
      source = Class.new(Glazed::Secrets::Base) do
        define_singleton_method(:from_proto) { |settings| new.tap { log << it } }
        define_method(:value) { "secret-#{object_id}" }
      end
      Glazed::Secrets.register(settings_class, source)
    end

    after { Glazed::Secrets::PLUGINS.unregister(settings_class) }

    it 'builds the source of a reference once and keeps it' do
      expect(resolver.value(ref)).to eq(resolver.secret(ref.dup).value)
      expect(built.size).to eq(1)
    end

    it 'keeps sources apart between resolvers' do
      expect(resolver.value(ref)).not_to eq(described_class.new.value(ref))
      expect(built.size).to eq(2)
    end
  end
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/secret'

RSpec.describe Glazed::Secret do
  def secret(**source) = described_class.new(Glazed::Proto::V1::SecretRef.new(**source))

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
    expect(described_class.maybe(nil)).to be_nil
  end
end

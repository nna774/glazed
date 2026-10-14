# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/secrets_resolver'
require 'glazed/secrets/shell'

RSpec.describe Glazed::Secrets::Shell do
  def secret(**settings) = Glazed::SecretsResolver.new.secret(Glazed::Proto::V1::SecretRef.new(shell: settings))

  it 'reads what the command prints without its trailing newline' do
    expect(secret(run: 'echo s3cret').value).to eq('s3cret')
  end

  it 'reads what a program prints when run with its arguments' do
    expect(secret(command: ['printf', '%s\n', 's3cret; x']).value).to eq('s3cret; x')
  end

  it 'runs the command each time the value is read' do
    Dir.mktmpdir do |dir|
      counter = File.join(dir, 'count')
      ref = secret(run: "echo x >> #{counter}; wc -l < #{counter}")
      expect([ref.value.strip, ref.value.strip]).to eq(%w[1 2])
    end
  end

  it 'raises Unavailable when the command fails' do
    expect { secret(run: 'echo locked >&2; exit 1').value }
      .to raise_error(Glazed::Secret::Unavailable, /exited with 1: locked/)
  end

  it 'raises Unavailable when the program cannot be executed' do
    expect { secret(command: ['/nonexistent/glazed']).value }.to raise_error(Glazed::Secret::Unavailable, /could not start/)
  end

  it 'raises Unavailable when the command times out' do
    expect { described_class.new(run: 'sleep 5', timeout: 0.1).value }.to raise_error(Glazed::Secret::Unavailable, /did not finish/)
  end

  it 'uses the default timeout when the settings set none' do
    expect(described_class.from_proto(Glazed::Proto::V1::ShellSecret.new(run: 'true')).timeout)
      .to eq(described_class::DEFAULT_TIMEOUT)
  end
end

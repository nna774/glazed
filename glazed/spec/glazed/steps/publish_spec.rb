# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'open3'
require 'tmpdir'
require 'glazed/steps/publish'
require 'glazed/storages/git'

RSpec.describe Glazed::Steps::Publish do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:raw_storage) { Glazed::Storages::Git.new(path: File.join(@dir, 'raw')) }
  let(:redacted_storage) { Glazed::Storages::Git.new(path: File.join(@dir, 'redacted')) }
  let(:redaction) { Glazed::Proto::V1::Redaction.new(mode: :MODE_REMOVE) }
  let(:publish) { described_class.new(raw_storage:, redacted_storage:, redaction:) }
  let(:dialect) do
    Class.new(Glazed::Dialects::Base) do
      sensitive_pattern(/^password (\S+)/) { it[1] }
    end
  end

  before { stub_const('Glazed::Dialects::TestOs', dialect) }

  def entry(name)
    node = Glazed::Proto::V1::Node.new(name:, group: 'core', dialect: 'test_os')
    raw = raw_storage.write(key: "core/#{name}", content: "hostname #{name}\npassword hunter2\n", message: name)
    Glazed::Proto::V1::FetchResult.new(node:, raw:)
  end

  it 'redacts every entry into one commit' do
    result = publish.call(Glazed::Proto::V1::PublishRequest.new(entries: [entry('rt1'), entry('rt2')]))
    expect(result.redacted.map { it.git.path }).to eq(%w[core/rt1 core/rt2])
    expect(redacted_storage.read(result.redacted.first)).to eq("hostname rt1\npassword <secret removed>\n")
    log = Open3.capture2('git', '-C', redacted_storage.path, 'log', '--format=%s').first
    expect(log).to eq("update rt1, rt2\n")
  end

  it 'shortens the message for many nodes' do
    names = %w[a b c d e f g]
    publish.call(Glazed::Proto::V1::PublishRequest.new(entries: names.map { entry(it) }))
    log = Open3.capture2('git', '-C', redacted_storage.path, 'log', '--format=%s').first
    expect(log).to eq("update a, b, c, d, e and 2 more\n")
  end

  it 'publishes nothing for no entries' do
    expect(publish.call(Glazed::Proto::V1::PublishRequest.new).redacted).to be_empty
    expect(File.exist?(redacted_storage.path)).to be(false)
  end
end

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

  let(:staging) { Glazed::Storages::Git.new(path: File.join(@dir, 'staging')) }
  let(:team) { Glazed::Storages::Git.new(path: File.join(@dir, 'team')) }
  let(:context) { Glazed::Steps::Context.new(storages: {'staging' => staging, 'team' => team}) }
  let(:settings) { Glazed::Proto::V1::PublishStep.new(input: 'redacted', storage: 'team') }
  let(:step) { described_class.from_proto('publish', settings, context:) }

  def state(name)
    pointer = staging.write(key: "core/#{name}", content: "hostname #{name}\n", message: name).pointer
    Glazed::Proto::V1::NodeState.new(node: {name:, group: 'core'}, artifacts: {'redacted' => {storage: 'staging', pointer:}})
  end

  def log = Open3.capture2('git', '-C', team.path, 'log', '--format=%s').first

  it 'writes every node in one commit' do
    step.call(Glazed::Proto::V1::BatchState.new(nodes: [state('rt1'), state('rt2')]))
    expect(log).to eq("publish: update rt1, rt2\n")
    expect(Open3.capture2('git', '-C', team.path, 'show', 'HEAD:core/rt2').first).to eq("hostname rt2\n")
  end

  it 'shortens the message for many nodes' do
    step.call(Glazed::Proto::V1::BatchState.new(nodes: %w[a b c d e f g].map { state(it) }))
    expect(log).to eq("publish: update a, b, c, d, e and 2 more\n")
  end

  it 'records the written locations when an output is set' do
    settings.output = 'published'
    batch = step.call(Glazed::Proto::V1::BatchState.new(nodes: [state('rt1')]))
    artifact = batch.nodes.first.artifacts['published']
    expect(artifact.storage).to eq('team')
    expect(context.read(artifact)).to eq("hostname rt1\n")
  end

  it 'writes nothing for no nodes' do
    expect(step.call(Glazed::Proto::V1::BatchState.new).nodes).to be_empty
    expect(File.exist?(team.path)).to be(false)
  end
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'open3'
require 'tmpdir'
require 'glazed/storages/git'

RSpec.describe Glazed::Storages::Git do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, 'repo') }
  let(:storage) { described_class.new(path:) }

  def git(*args, path: self.path) = Open3.capture2('git', '-C', path, *args).first

  it 'initialises the repository and commits a file' do
    result = storage.write(key: 'core/rt1', content: "hostname rt1\n", message: 'rt1')
    expect(result).to be_changed
    expect(result.pointer.git.path).to eq('core/rt1')
    expect(result.pointer.git.commit).to eq(git('rev-parse', 'HEAD').strip)
    expect(git('log', '--format=%s %an <%ae>')).to eq("rt1 glazed <glazed@localhost>\n")
    expect(git('branch', '--show-current')).to eq("main\n")
  end

  it 'reads content at the pointed commit' do
    first = storage.write(key: 'rt1', content: "v1\n", message: 'v1')
    storage.write(key: 'rt1', content: "v2\n", message: 'v2')
    expect(storage.read(first.pointer)).to eq("v1\n")
  end

  it 'writes several files in one commit' do
    results = storage.write_all([['a/rt1', "1\n"], ['b/rt2', "2\n"]], message: ->(_) { 'batch' })
    expect(results.map { it.pointer.git.path }).to eq(%w[a/rt1 b/rt2])
    expect(git('rev-list', '--count', 'HEAD')).to eq("1\n")
  end

  it 'makes no commit for unchanged content and reports it unchanged' do
    first = storage.write(key: 'rt1', content: "same\n", message: 'one')
    second = storage.write(key: 'rt1', content: "same\n", message: 'two')
    expect(second).not_to be_changed
    expect(second.pointer.git.commit).to eq(first.pointer.git.commit)
    expect(git('rev-list', '--count', 'HEAD')).to eq("1\n")
  end

  it 'builds the message from the changed keys only' do
    storage.write_all([['rt1', "1\n"], ['rt2', "2\n"]], message: ->(_) { 'first' })
    keys = nil
    results = storage.write_all([['rt1', "1\n"], ['rt2', "3\n"]], message: ->(changed) { 'second'.tap { keys = changed } })
    expect(keys).to eq(['rt2'])
    expect(results.map(&:changed?)).to eq([false, true])
    expect(git('log', '-1', '--format=%s')).to eq("second\n")
  end

  it 'does not build a message when nothing changed' do
    storage.write(key: 'rt1', content: "x\n", message: 'x')
    expect { storage.write_all([['rt1', "x\n"]], message: ->(_) { raise 'unexpected' }) }.not_to raise_error
  end

  it 'commits to the configured branch' do
    described_class.new(path:, branch: 'configs').write(key: 'rt1', content: "x\n", message: 'x')
    expect(git('branch', '--show-current')).to eq("configs\n")
  end

  it 'rejects keys that could escape the repository' do
    ['../x', '/abs', 'a//b', 'a/./b', ''].each do |key|
      expect { storage.write(key:, content: '', message: 'x') }.to raise_error(Glazed::Storages::Base::InvalidKey)
    end
  end

  it 'raises CommandFailed with git output for a missing commit' do
    storage.write(key: 'rt1', content: "x\n", message: 'x')
    pointer = Glazed::Proto::V1::Pointer.new(git: {path: 'rt1', commit: '0' * 40})
    expect { storage.read(pointer) }.to raise_error(described_class::CommandFailed, /git show failed/)
  end

  context 'with a remote' do
    let(:remote) { File.join(@dir, 'remote.git').tap { system('git', 'init', '--quiet', '--bare', it, exception: true) } }

    it 'pushes commits and pulls them into another working tree' do
      described_class.new(path:, remote:).write(key: 'rt1', content: "v1\n", message: 'v1')
      other = described_class.new(path: File.join(@dir, 'other'), remote:)
      other.write(key: 'rt2', content: "v2\n", message: 'v2')
      expect(git('log', '--format=%s', 'main', path: remote)).to eq("v2\nv1\n")
    end
  end

  describe '.from_proto' do
    it 'fills defaults for empty fields' do
      storage = described_class.from_proto(Glazed::Proto::V1::GitStorage.new(path: '/x'))
      expect([storage.path, storage.branch, storage.remote]).to eq(['/x', 'main', nil])
    end
  end
end

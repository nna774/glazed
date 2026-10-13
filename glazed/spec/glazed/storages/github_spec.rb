# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'digest'
require 'webmock/rspec'
require 'httpx/adapters/webmock'
require 'glazed/storages/github'

RSpec.describe Glazed::Storages::Github do
  def location(pointer) = pointer.location.unpack(Glazed::Proto::V1::GithubLocation)
  def pointer_to(**location) = Glazed::Proto::V1::Pointer.new(location: Google::Protobuf::Any.pack(Glazed::Proto::V1::GithubLocation.new(**location)))

  let(:api) { 'https://api.github.com/repos/org/netconf' }
  let(:token) { Glazed::Secret.new(Glazed::Proto::V1::SecretRef.new(value: 'tok')) }
  let(:storage) { described_class.new(repository: 'org/netconf', branch: 'glazed/auto', token:) }
  let(:files) { [['core/rt1', "hostname rt1\n"]] }
  let(:message) { ->(keys) { "update #{keys.join(', ')}" } }

  def reply(body, status: 200) = {status:, body: JSON.generate(body), headers: {'content-type' => 'application/json'}}

  def blob(content) = Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")

  def stub_listing(tree, entries, truncated: false)
    stub_request(:get, "#{api}/git/trees/#{tree}?recursive=1")
      .to_return(reply({sha: tree, truncated:, tree: entries.map { |path, sha| {path:, type: 'blob', sha:} }}))
  end

  def stub_tree(base_tree:, entries:, result:)
    stub_request(:post, "#{api}/git/trees")
      .with(body: {base_tree:, tree: entries.map { |path, content| {path:, mode: '100644', type: 'blob', content:} }})
      .to_return(reply({sha: result}))
  end

  context 'when the branch exists' do
    before do
      stub_request(:get, "#{api}/git/ref/heads/glazed/auto")
        .with(headers: {'authorization' => 'Bearer tok', 'x-github-api-version' => '2022-11-28'})
        .to_return(reply({object: {sha: 'head'}}))
      stub_request(:get, "#{api}/git/commits/head").to_return(reply({tree: {sha: 'base-tree'}}))
    end

    it 'commits changed files on top of the head and moves the branch' do
      stub_listing('base-tree', {'core/rt1' => blob("old\n")})
      stub_tree(base_tree: 'base-tree', entries: files, result: 'new-tree')
      commit = stub_request(:post, "#{api}/git/commits")
               .with(body: {message: 'update core/rt1', tree: 'new-tree', parents: ['head']})
               .to_return(reply({sha: 'new-commit'}))
      ref = stub_request(:patch, "#{api}/git/refs/heads/glazed/auto")
            .with(body: {sha: 'new-commit', force: false})
            .to_return(reply({}))

      result = storage.write_all(files, message:).first
      expect(result).to be_changed
      expect(location(result.pointer).to_h).to eq(repository: 'org/netconf', path: 'core/rt1', commit: 'new-commit')
      expect([commit, ref]).to all(have_been_requested)
    end

    it 'sends only changed files and names only them in the message' do
      stub_listing('base-tree', {'core/rt1' => blob("hostname rt1\n"), 'core/rt2' => blob("old\n")})
      stub_tree(base_tree: 'base-tree', entries: [['core/rt2', "hostname rt2\n"]], result: 'new-tree')
      stub_request(:post, "#{api}/git/commits").with(body: hash_including(message: 'update core/rt2')).to_return(reply({sha: 'new-commit'}))
      stub_request(:patch, "#{api}/git/refs/heads/glazed/auto").to_return(reply({}))

      results = storage.write_all([['core/rt1', "hostname rt1\n"], ['core/rt2', "hostname rt2\n"]], message:)
      expect(results.map(&:changed?)).to eq([false, true])
      expect(results.map { location(it.pointer).commit }).to all(eq('new-commit'))
    end

    it 'makes no request beyond reading when every file is unchanged' do
      stub_listing('base-tree', {'core/rt1' => blob("hostname rt1\n")})
      result = storage.write_all(files, message: ->(_) { raise 'unexpected' }).first
      expect(result).not_to be_changed
      expect(location(result.pointer).commit).to eq('head')
      expect(a_request(:post, %r{/git/})).not_to have_been_made
      expect(a_request(:patch, %r{/git/refs/})).not_to have_been_made
    end

    it 'falls back to comparing trees when the listing is truncated' do
      stub_listing('base-tree', {}, truncated: true)
      stub_tree(base_tree: 'base-tree', entries: files, result: 'base-tree')
      result = storage.write_all(files, message:).first
      expect(result).not_to be_changed
      expect(a_request(:post, "#{api}/git/commits")).not_to have_been_made
    end

    it 'retries when the branch moved concurrently' do
      stub_listing('base-tree', {})
      stub_tree(base_tree: 'base-tree', entries: files, result: 'new-tree')
      stub_request(:post, "#{api}/git/commits").to_return(reply({sha: 'new-commit'}))
      stub_request(:patch, "#{api}/git/refs/heads/glazed/auto")
        .to_return(reply({message: 'Update is not a fast forward'}, status: 422)).then
        .to_return(reply({}))

      expect(location(storage.write_all(files, message:).first.pointer).commit).to eq('new-commit')
      expect(a_request(:get, "#{api}/git/ref/heads/glazed/auto")).to have_been_made.twice
    end

    it 'raises ApiError after repeated conflicts' do
      stub_listing('base-tree', {})
      stub_tree(base_tree: 'base-tree', entries: files, result: 'new-tree')
      stub_request(:post, "#{api}/git/commits").to_return(reply({sha: 'new-commit'}))
      stub_request(:patch, "#{api}/git/refs/heads/glazed/auto").to_return(reply({}, status: 422))

      expect { storage.write_all(files, message:) }.to raise_error(described_class::ApiError) { expect(it.status).to eq(422) }
    end
  end

  context 'when the branch is missing' do
    before do
      stub_request(:get, "#{api}/git/ref/heads/glazed/auto").to_return(reply({message: 'Not Found'}, status: 404))
      stub_request(:get, api).to_return(reply({default_branch: 'main'}))
      stub_request(:get, "#{api}/git/ref/heads/main").to_return(reply({object: {sha: 'main-head'}}))
      stub_request(:get, "#{api}/git/commits/main-head").to_return(reply({tree: {sha: 'main-tree'}}))
      stub_listing('main-tree', {})
      stub_tree(base_tree: 'main-tree', entries: files, result: 'new-tree')
      stub_request(:post, "#{api}/git/commits")
        .with(body: {message: 'update core/rt1', tree: 'new-tree', parents: ['main-head']})
        .to_return(reply({sha: 'new-commit'}))
    end

    it 'creates it from the default branch' do
      create = stub_request(:post, "#{api}/git/refs")
               .with(body: {ref: 'refs/heads/glazed/auto', sha: 'new-commit'})
               .to_return(reply({}, status: 201))
      expect(location(storage.write_all(files, message:).first.pointer).commit).to eq('new-commit')
      expect(create).to have_been_requested
    end
  end

  it 'reads raw content at the pointed commit' do
    stub_request(:get, "#{api}/contents/core/rt1?ref=abc")
      .with(headers: {'accept' => 'application/vnd.github.raw+json'})
      .to_return(status: 200, body: "hostname rt1\n")
    pointer = pointer_to(repository: 'org/netconf', path: 'core/rt1', commit: 'abc')
    expect(storage.read(pointer)).to eq("hostname rt1\n")
  end

  describe '.from_proto' do
    it 'requires a token' do
      settings = Glazed::Proto::V1::GithubStorage.new(repository: 'org/netconf', branch: 'b')
      expect { described_class.from_proto(settings) }.to raise_error(ArgumentError, /token/)
    end
  end
end

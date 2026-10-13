# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'tmpdir'
require 'glazed/sources'

RSpec.describe Glazed::Sources do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def file(name, nodes)
    File.join(@dir, name).tap { File.write(it, JSON.generate(nodes:)) }
  end

  def json_files(*paths) = Glazed::Proto::V1::InventorySource.new(json_files: {paths:})

  describe '.build' do
    it 'builds the selected provider' do
      provider = described_class.build(json_files('a.json'))
      expect(provider).to be_a(Glazed::Sources::JsonFiles).and(have_attributes(paths: ['a.json']))
    end

    it 'raises MissingProvider for an empty source' do
      expect { described_class.build(Glazed::Proto::V1::InventorySource.new) }.to raise_error(described_class::MissingProvider)
    end
  end

  describe '.nodes' do
    it 'concatenates nodes of every source in order' do
      a = file('a.json', [{name: 'rt1', dialect: 'ios'}])
      b = file('b.json', [{name: 'rt2', dialect: 'ios'}])
      expect(described_class.nodes([json_files(b), json_files(a)]).map(&:name)).to eq(%w[rt2 rt1])
    end

    it 'raises DuplicateNode across sources naming both' do
      a = file('a.json', [{name: 'rt1', dialect: 'ios'}])
      b = file('b.json', [{name: 'rt1', dialect: 'ios'}])
      expect { described_class.nodes([json_files(a), json_files(b)]) }
        .to raise_error(described_class::DuplicateNode, /json_files #{a} and json_files #{b}/)
    end

    it 'reads providers registered outside the core' do
      provider = Class.new(Glazed::Sources::Base) do
        define_singleton_method(:from_proto) { |_settings| new }
        define_method(:nodes) { [Glazed::Proto::V1::Node.new(name: 'ext1', dialect: 'ios')] }
      end
      stub_const('Glazed::Sources::JsonFiles', provider)
      expect(described_class.nodes([json_files]).map(&:name)).to eq(['ext1'])
    end
  end
end

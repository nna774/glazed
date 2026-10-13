# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Under Ruby::Box on Ruby 4.0.7, rspec fails to shellsplit .rspec lines, so there is no .rspec.
require 'spec_helper'
require 'glazed/collector'

RSpec.describe Glazed::Oxidized do
  it 'has a version number' do
    expect(Glazed::Oxidized::VERSION).not_to be_nil
  end

  describe 'dialect lookup' do
    it 'resolves oxidized_<model> to a dialect running the model' do
      dialect = Glazed::Dialects.find('oxidized_aireos')
      expect(dialect).to be < Glazed::Oxidized::ModelDialect
      expect(dialect.name).to eq('Glazed::Dialects::OxidizedAireos')
      expect(dialect.model_box.path).to eq(File.join(FIXTURE_MODELS, 'aireos.rb'))
    end

    it 'loads each model once' do
      expect(Glazed::Dialects.find('oxidized_junos')).to equal(Glazed::Dialects.find('oxidized_junos'))
    end

    it 'takes the prompt and comment prefix from the model' do
      dialect = Glazed::Dialects.find('oxidized_aireos')
      expect(dialect.prompt_pattern).to eq(/^\([^)]+\)\s>/)
      expect(dialect.comment_prefix_value).to eq('# ')
    end

    it "uses Oxidized's default prompt when the model declares none" do
      expect(Glazed::Dialects.find('oxidized_minimal').prompt_pattern).to eq(Glazed::Oxidized::ModelDialect::DEFAULT_PROMPT)
    end

    it 'raises NotFound when no model file has the name' do
      expect { Glazed::Dialects.find('oxidized_nonexistent') }.to raise_error(Glazed::Finder::NotFound)
    end

    it 'raises ModelNotFound when the file defines no model by its name' do
      expect { Glazed::Dialects.find('oxidized_nomodel') }.to raise_error(Glazed::Oxidized::ModelNotFound)
    end
  end

  describe '.model_path' do
    it 'searches model_paths in order' do
      other = File.expand_path('fixtures/other', __dir__)
      described_class.model_paths = [other, FIXTURE_MODELS]
      expect(described_class.model_path('junos')).to eq(File.join(FIXTURE_MODELS, 'junos.rb'))
    ensure
      described_class.model_paths = [FIXTURE_MODELS]
    end

    it 'rejects names that are not file names' do
      expect(described_class.model_path('../model/junos')).to be_nil
    end
  end

  describe 'collecting with Oxidized models' do
    def node(dialect, transport: 'ssh', **fields)
      Glazed::Proto::V1::Node.new(name: 'rt1', dialect:, transport:, username: 'admin', password: {value: 'pw'}, **fields)
    end

    it 'collects with the aireos model as the wlc dialect does' do
      simulation = Simulation.load('wlc/wlc2504')
      stub_const('Glazed::Transports::Ssh', simulation.shell_device)
      collected = Glazed::Collector.new(node: node('oxidized_aireos'), timeout: 1).call
      # The model leaves blank lines between its comment blocks uncommented.
      expect(collected).to eq(simulation.expected('collected').gsub(/^#\n/, "\n"))
    end

    it 'collects with the junos model over exec channels' do
      simulation = Simulation.load('junos/srx300_22.4')
      stub_const('Glazed::Transports::Ssh', simulation.exec_device)
      collected = Glazed::Collector.new(node: node('oxidized_junos'), timeout: 1).call
      # Oxidized keeps the space after the comment prefix on empty lines.
      expect(collected.gsub(/^# $/, '#')).to eq(simulation.expected('collected'))
    end

    context 'with a model using the wider API' do
      let(:responses) do
        {
          'admin' => "Password: ",
          'pw' => "\r\nrt> ",
          'enable' => "Password: ",
          's3cret' => "\r\nrt# ",
          'terminal length 0' => "rt# ",
          'show version' => "Rootware 1.0\r\nrt# ",
          'show config' => "hostname rt\r\nsnmp community public\r\nrt# ",
          'show extra' => "extra info\r\nrt# ",
          'exit' => '',
          '' => '',
        }
      end
      let(:device) { FakeTransport.device(greeting: 'login: ', responses:, pager: 2) }
      let(:rootware) do
        node(
          'oxidized_rootware', transport: 'telnet',
          params: {'site' => 'tokyo', 'verbose' => 'true', 'remove_secret' => 'true'},
          secrets: {'enable' => {value: 's3cret'}}
        )
      end

      before { stub_const('Glazed::Transports::Telnet', device) }

      it 'runs commands, expect, pre, post and secret blocks' do
        collected = Glazed::Collector.new(node: rootware, timeout: 1).call
        expect(collected).to eq(<<~CONFIG)
          ! model tokyo true
          ! Rootware 1.0
          hostname rt
          snmp community <hidden>
          ! extra info
        CONFIG
      end

      it 'logs in and runs post_login and pre_logout' do
        Glazed::Collector.new(node: rootware, timeout: 1).call
        written = device.instances.first.written
        expect(written.first(5)).to eq(["admin\n", "pw\n", "enable\n", "s3cret\n", "terminal length 0\n"])
        expect(written.last).to eq("exit\r\n")
        expect(written).to include(' ')
      end

      it 'keeps secrets unless remove_secret is set' do
        rootware.params.delete('remove_secret')
        expect(Glazed::Collector.new(node: rootware, timeout: 1).call).to include('snmp community public')
      end

      it "keeps the model's monkey patches and globals inside its box" do
        Glazed::Collector.new(node: rootware, timeout: 1).call
        expect(''.respond_to?(:rootware_patched?)).to be(false)
        expect(defined?(::RootWare)).to be_nil
        expect(defined?(::ROOTWARE_CONSTANT)).to be_nil
        expect(defined?(::Oxidized)).to be_nil
        expect(defined?(::Refinements)).to be_nil
        expect($rootware_global).to be_nil # rubocop:disable Style/GlobalVars
      end
    end

    it 'fails nodes on transports the model has no cfg block for' do
      stub_const('Glazed::Transports::Telnet', FakeTransport.device(greeting: 'rt1# '))
      expect { Glazed::Collector.new(node: node('oxidized_minimal', transport: 'telnet'), timeout: 1).call }
        .to raise_error(Glazed::Oxidized::UnsupportedTransport, /minimal has no cfg block for telnet/)
    end
  end
end

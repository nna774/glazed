# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/transports/ssh'

RSpec.describe Glazed::Transports::Ssh do
  describe '#open' do
    let(:password) { Glazed::SecretsResolver.new.secret(Glazed::Proto::V1::SecretRef.new(value: 'pw')) }
    let(:transport_options) { nil }
    let(:transport) { described_class.new(host: 'rt1', port: 2222, username: 'admin', password:, transport_options:) }
    let(:session) { instance_double(Net::SSH::Connection::Session) }
    let(:managed) { {port: 2222, password: 'pw', timeout: 15, non_interactive: true} }

    before { allow(Net::SSH).to receive(:start).and_return(session) }

    def options(**ssh) = Glazed::Proto::V1::TransportOptions.new(ssh:)

    it 'leaves net-ssh defaults when no options are set' do
      transport.open
      expect(Net::SSH).to have_received(:start).with('rt1', 'admin', **managed)
    end

    context 'with scalar and list options' do
      let(:transport_options) do
        options(
          auth_methods: %w[publickey], verify_host_key: :HOST_KEY_VERIFICATION_NEVER, keys_only: true,
          user_known_hosts_file: %w[/etc/kh], compression: true, forward_agent: true,
          number_of_password_prompts: 1, use_ssh_config: false, kex: %w[curve25519-sha256],
        )
      end

      it 'passes them to net-ssh' do
        transport.open
        expect(Net::SSH).to have_received(:start).with(
          'rt1', 'admin',
          config: false, auth_methods: %w[publickey], verify_host_key: :never, keys_only: true,
          user_known_hosts_file: %w[/etc/kh], compression: true, forward_agent: true,
          number_of_password_prompts: 1, kex: %w[curve25519-sha256], **managed,
        )
      end
    end

    context 'with keys' do
      let(:transport_options) do
        options(
          keys: [{path: '/keys/id'}, {raw: {value: 'PEM1'}}, {raw: {env: 'GLAZED_TEST_KEY'}}],
          passphrase: {value: 'phrase'},
        )
      end

      around do |example|
        ENV['GLAZED_TEST_KEY'] = 'PEM2'
        example.run
      ensure
        ENV.delete('GLAZED_TEST_KEY')
      end

      it 'passes paths as keys and resolves raw keys into key_data' do
        transport.open
        expect(Net::SSH).to have_received(:start).with(
          'rt1', 'admin', keys: ['/keys/id'], key_data: %w[PEM1 PEM2], passphrase: 'phrase', **managed,
        )
      end
    end

    context 'with a proxy command' do
      let(:transport_options) { options(proxy_command: 'ssh jump nc %h %p') }

      it 'passes a proxy' do
        transport.open
        expect(Net::SSH).to have_received(:start).with('rt1', 'admin', hash_including(proxy: be_a(Net::SSH::Proxy::Command)))
      end
    end

    context 'with options for another transport only' do
      let(:transport_options) { Glazed::Proto::V1::TransportOptions.new }

      it 'behaves as without options' do
        transport.open
        expect(Net::SSH).to have_received(:start).with('rt1', 'admin', **managed)
      end
    end
  end

  describe '#close' do
    let(:transport) { described_class.new(host: 'rt1', port: nil, username: 'admin', password: nil) }
    let(:channels) { {0 => instance_double(Net::SSH::Connection::Channel, close: nil)} }
    let(:session) { instance_double(Net::SSH::Connection::Session, closed?: false, channels:, close: nil, shutdown!: nil) }

    before do
      allow(Net::SSH).to receive(:start).and_return(session)
      stub_const('Glazed::Transports::Ssh::CLOSE_TIMEOUT', 0.05)
      transport.open
    end

    it 'closes the session once the device acknowledges closing channels' do
      allow(session).to receive(:loop) { channels.clear }
      transport.close
      expect(session).to have_received(:close)
    end

    it 'drops the connection when the device never acknowledges' do
      allow(session).to receive(:loop) { |_wait, &condition| nil while condition.call }
      transport.close
      expect(session).to have_received(:shutdown!)
      expect(session).not_to have_received(:close)
    end
  end
end

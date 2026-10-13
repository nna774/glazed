# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/transports/ssh'

RSpec.describe Glazed::Transports::Ssh do
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

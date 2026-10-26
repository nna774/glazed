# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/eos'

RSpec.describe Glazed::Dialects::Eos do
  it_behaves_like 'a dialect simulation', 'eos/dcs7050', transport: 'ssh'
  it_behaves_like 'a dialect simulation', 'eos/cEOSLab_4.32.2F', transport: 'ssh'
  it_behaves_like 'a dialect simulation', 'eos/cEOSLab_4.32.2F_enable', transport: 'ssh',
    node_secrets: {'enable' => 'Xq7enable'}

  describe 'login' do
    let(:responses) do
      {
        'enable' => 'Password: ',
        'en4ble' => "\r\nswitch1#",
        'terminal length 0' => 'switch1#',
        'show inventory | no-more' => 'switch1#',
        'show running-config | no-more | exclude ! Time:' => "hostname switch1\r\nswitch1#",
        'exit' => '',
      }
    end
    let(:device) { FakeTransport.device(greeting: 'switch1>', responses:) }

    before { stub_const('Glazed::Transports::Ssh', device) }

    def collect(**node) = Glazed::Collector.new(node: Glazed::Proto::V1::Node.new(name: 'sw1', dialect: 'eos', **node), timeout: 1).call

    it 'enters enable mode with the enable secret' do
      collect(secrets: {'enable' => {value: 'en4ble'}})
      expect(device.instances.first.written.first(3)).to eq(["enable\n", "en4ble\n", "terminal length 0\n"])
    end

    it 'runs enable without a password when the param asks for it' do
      responses['enable'] = 'switch1#'
      collect(params: {'enable' => 'true'})
      expect(device.instances.first.written.first(2)).to eq(["enable\n", "terminal length 0\n"])
    end

    it 'skips enable by default' do
      collect
      expect(device.instances.first.written.first).to eq("terminal length 0\n")
    end
  end

  # Secret lines beyond the device captures, from the EOS 4.32 user manual with random values.
  describe 'sensitive patterns' do
    def redact(line) = Glazed::Redactor.new(patterns: described_class.sensitive_patterns, mode: :remove).call("#{line}\n").chomp

    {
      'aaa root secret sha512 $6$Rk3vQm9wZb$aRootHash.' => 'aaa root secret sha512 [~REDACTED~]',
      'enable secret 5 $1$Ab1cD2eF$enableMd5Hash000' => 'enable secret 5 [~REDACTED~]',
      'username backup privilege 15 role network-operator secret 5 $1$Zx9cVb$backupMd5Hash00000000' =>
        'username backup privilege 15 role network-operator secret 5 [~REDACTED~]',
      'service unsupported-transceiver ExampleCorp 1a2b3c4d' => 'service unsupported-transceiver ExampleCorp [~REDACTED~]',
      'ntp authentication-key 1 md5 7 094F471A1A0A464058' => 'ntp authentication-key 1 md5 7 [~REDACTED~]',
      'tacacs-server key 7 070C285F4D061A0A19' => 'tacacs-server key 7 [~REDACTED~]',
      'snmp-server host 192.0.2.60 version 2c Hst2cmty' => 'snmp-server host 192.0.2.60 version 2c [~REDACTED~]',
      'snmp-server host 192.0.2.61 vrf MGMT informs version 3 auth snmpv3user' =>
        'snmp-server host 192.0.2.61 vrf MGMT informs version 3 auth snmpv3user',
      '      key 0a1b2c3d4e5f60718293a4b5c6d7e8f9 7 112A1016141D5B5E737B6D7B7D1F0B0C1E1D1F1D1F' =>
        '      key 0a1b2c3d4e5f60718293a4b5c6d7e8f9 7 [~REDACTED~]',
      '      secret 1 7 05080F1C2243185E5D0A1B infinite infinite' => '      secret 1 7 [~REDACTED~] infinite infinite',
      '   ip ospf authentication-key 7 0822455D0A16544541' => '   ip ospf authentication-key 7 [~REDACTED~]',
      '   ip ospf message-digest-key 1 md5 7 13061E010803557878' => '   ip ospf message-digest-key 1 md5 7 [~REDACTED~]',
      '   isis authentication key 7 060506324F41584B56' => '   isis authentication key 7 [~REDACTED~]',
      '   authentication key 7 0703204E5F1E0B0C1C' => '   authentication key 7 [~REDACTED~]',
      '   vrrp 1 peer authentication text Vr3pTxt' => '   vrrp 1 peer authentication text [~REDACTED~]',
      '   vrrp 2 peer authentication ietf-md5 key-string 7 104D000A061843595F' =>
        '   vrrp 2 peer authentication ietf-md5 key-string 7 [~REDACTED~]',
      '   neighbor SPINE password 7 Bgp0PgEncrypted+==' => '   neighbor SPINE password 7 [~REDACTED~]',
      # A public key, not a secret.
      'username admin ssh-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample admin@example' =>
        'username admin ssh-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample admin@example',
    }.each do |line, redacted|
      it "redacts #{line.strip}" do
        expect(redact(line)).to eq(redacted)
      end
    end
  end
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/redactor'

RSpec.describe Glazed::Redactor do
  def pattern(regexp, &determiner) = Glazed::Dialect::SensitivePattern.new(pattern: regexp, determiner: determiner || ->(m) { m[1] })

  let(:patterns) do
    [
      pattern(/^username (\S+) password \d (\S+)/) { it[2] },
      pattern(/^snmp-server community (\S+)/),
      pattern(/^tacacs server \S+\n(?: .+\n)*? key (\S+)/),
    ]
  end
  let(:config) do
    <<~CONFIG
      hostname rt1
      username admin password 7 admin
      snmp-server community public RO
      tacacs server t1
       address ipv4 192.0.2.1
       key tackey
    CONFIG
  end

  it 'removes only the secret within each match' do
    expect(described_class.new(patterns:, mode: :remove).call(config)).to eq(<<~CONFIG)
      hostname rt1
      username admin password 7 <secret removed>
      snmp-server community <secret removed> RO
      tacacs server t1
       address ipv4 192.0.2.1
       key <secret removed>
    CONFIG
  end

  it 'replaces secrets with a stable keyed digest in hmac mode' do
    redactor = described_class.new(patterns:, mode: :hmac, key: 'k')
    digest = OpenSSL::HMAC.hexdigest('SHA256', 'k', 'public')[0, 16]
    expect(redactor.call(config)).to include("snmp-server community <secret hmac:#{digest}> RO\n")
    expect(redactor.call(config)).to eq(redactor.call(config))
    expect(described_class.new(patterns:, mode: :hmac, key: 'other').call(config)).not_to eq(redactor.call(config))
  end

  it 'replaces every occurrence of a repeated pattern' do
    text = "snmp-server community a\nsnmp-server community b\n"
    expect(described_class.new(patterns:, mode: :remove).call(text)).not_to match(/community [ab]$/)
  end

  it 'keeps the first of overlapping secrets' do
    overlapping = [pattern(/^key (\S+ \S+)/), pattern(/^key \S+ (\S+)/)]
    expect(described_class.new(patterns: overlapping, mode: :remove).call("key a b\n")).to eq("key <secret removed>\n")
  end

  it 'skips matches whose determiner returns nil or empty' do
    skipping = [pattern(/^key (\S*)/) { nil }, pattern(/^key2 (\S*)/)]
    expect(described_class.new(patterns: skipping, mode: :remove).call("key a\nkey2 \n")).to eq("key a\nkey2 \n")
  end

  it 'rejects hmac without a key and unknown modes' do
    expect { described_class.new(patterns:, mode: :hmac) }.to raise_error(described_class::InvalidConfiguration)
    expect { described_class.new(patterns:, mode: :rot13) }.to raise_error(described_class::InvalidConfiguration)
  end

  describe '.from_proto' do
    it 'defaults to remove' do
      expect(described_class.from_proto(Glazed::Proto::V1::Redaction.new, patterns:).mode).to eq(:remove)
    end

    it 'reads the hmac key from its secret as base64' do
      redaction = Glazed::Proto::V1::Redaction.new(mode: :MODE_HMAC, hmac_key: {value: ['k'].pack('m0')})
      expect(described_class.from_proto(redaction, patterns:).call(config))
        .to eq(described_class.new(patterns:, mode: :hmac, key: 'k').call(config))
    end

    it 'rejects an hmac key that is not base64' do
      redaction = Glazed::Proto::V1::Redaction.new(mode: :MODE_HMAC, hmac_key: {value: 'not base64!'})
      expect { described_class.from_proto(redaction, patterns:) }.to raise_error(described_class::InvalidConfiguration, /base64/)
    end
  end
end

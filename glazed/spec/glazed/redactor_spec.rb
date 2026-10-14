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
      username admin password 7 [~REDACTED~]
      snmp-server community [~REDACTED~] RO
      tacacs server t1
       address ipv4 192.0.2.1
       key [~REDACTED~]
    CONFIG
  end

  it 'replaces secrets with a stable keyed digest in hmac mode' do
    redactor = described_class.new(patterns:, mode: :hmac, key: 'k')
    expect(redactor.call(config)).to include("snmp-server community [~REDACTED:dgst=u0xNJmeMH-E~] RO\n")
    expect(redactor.call(config)).to eq(redactor.call(config))
    expect(described_class.new(patterns:, mode: :hmac, key: 'other').call(config)).not_to eq(redactor.call(config))
  end

  it 'replaces every occurrence of a repeated pattern' do
    text = "snmp-server community a\nsnmp-server community b\n"
    expect(described_class.new(patterns:, mode: :remove).call(text)).not_to match(/community [ab]$/)
  end

  it 'keeps the first of overlapping secrets' do
    overlapping = [pattern(/^key (\S+ \S+)/), pattern(/^key \S+ (\S+)/)]
    expect(described_class.new(patterns: overlapping, mode: :remove).call("key a b\n")).to eq("key [~REDACTED~]\n")
  end

  it 'removes the offsets a determiner returns' do
    by_offsets = [pattern(/^key a a$/) { (it.begin(0) + 6)...it.end(0) }]
    expect(described_class.new(patterns: by_offsets, mode: :remove).call("key a a\n")).to eq("key a [~REDACTED~]\n")
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

    describe 'extra secrets' do
      def redaction(**) = Glazed::Proto::V1::Redaction.new(**)

      it 'hides every match of an inline regexp' do
        r = redaction(secrets: [{regexp: 'token-\d+'}])
        expect(described_class.from_proto(r, patterns: []).call("a token-1 b token-22\n")).to eq("a [~REDACTED~] b [~REDACTED~]\n")
      end

      it 'hides every occurrence of a referenced value' do
        r = redaction(secrets: [{ref: {value: 'hunter2'}}])
        expect(described_class.from_proto(r, patterns: []).call("pw hunter2 and hunter2\n")).to eq("pw [~REDACTED~] and [~REDACTED~]\n")
      end

      it 'splits a referenced value by delimiter, preferring the longest overlap' do
        r = redaction(secrets: [{ref: {value: 'abc,abcdef,,xyz'}, delimiter: ','}])
        expect(described_class.from_proto(r, patterns: []).call("abcdef xyz abc q\n")).to eq("[~REDACTED~] [~REDACTED~] [~REDACTED~] q\n")
      end

      it 'hides nothing for an empty referenced value' do
        r = redaction(secrets: [{ref: {value: ''}}])
        expect(described_class.from_proto(r, patterns: []).call("text\n")).to eq("text\n")
      end

      it 'reports an invalid regexp' do
        r = redaction(secrets: [{regexp: '('}])
        expect { described_class.from_proto(r, patterns: []) }.to raise_error(described_class::InvalidConfiguration, /regexp/)
      end

      it 'raises when the referenced secret is unavailable' do
        r = redaction(secrets: [{ref: {env: 'GLAZED_SPEC_MISSING_SECRET'}}])
        expect { described_class.from_proto(r, patterns: []) }.to raise_error(Glazed::Secret::Unavailable)
      end

      it 'combines global and per-step secrets and falls back to the global mode and key' do
        global = redaction(mode: :MODE_HMAC, hmac_key: {value: ['k'].pack('m0')}, secrets: [{regexp: 'aaa'}])
        step = redaction(secrets: [{regexp: 'bbb'}])
        redactor = described_class.from_proto(step, patterns: [], global:)
        expect(redactor.mode).to eq(:hmac)
        expect(redactor.call('aaa bbb ccc')).to match(/\A\[~REDACTED:dgst=[\w-]{11}~\] \[~REDACTED:dgst=[\w-]{11}~\] ccc\z/)
      end

      it 'prefers the step mode over the global mode' do
        global = redaction(mode: :MODE_HMAC, hmac_key: {value: ['k'].pack('m0')})
        expect(described_class.from_proto(redaction(mode: :MODE_REMOVE), patterns: [], global:).mode).to eq(:remove)
      end
    end
  end
end

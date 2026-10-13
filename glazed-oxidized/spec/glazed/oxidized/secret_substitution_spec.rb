# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'spec_helper'

RSpec.describe Glazed::Oxidized::SecretSubstitution do
  def dropped(pattern, replacement, text)
    match = pattern.match(text) or raise "#{pattern.inspect} does not match #{text.inspect}"
    offsets = described_class.new(pattern:, replacement:).offsets(match)
    offsets && text[offsets]
  end

  it 'keeps the groups the replacement refers back to' do
    expect(dropped(/^(snmp-server community) \S+ (RO)/, '\\1 <hidden> \\2', "snmp-server community public RO\n")).to eq('public')
  end

  it 'expands named and whole-match backreferences' do
    expect(dropped(/(?<key>key) \S+/, '\\k<key> x', 'key secret')).to eq('secret')
    expect(dropped(/key/, '\\&', 'key')).to be_nil
  end

  it 'keeps the literal start the replacement shares with the match' do
    expect(dropped(/password (\S+).*/, 'password <secret removed>', 'password s3cret extra')).to eq('s3cret extra')
  end

  it 'does not keep part of a secret that begins like the replacement' do
    expect(dropped(/password \S+/, 'password secret-removed', 'password s3cret')).to eq('s3cret')
  end

  it 'trims whitespace around the dropped text' do
    expect(dropped(/(community) \S+/, '\\1', 'community public')).to eq('public')
  end

  it 'drops the whole match when the replacement shares nothing with it' do
    expect(dropped(/ssh-rsa "\S+"/, '<secret removed>', 'ssh-rsa "AAAA"')).to eq('ssh-rsa "AAAA"')
  end

  it 'returns offsets in the whole text' do
    text = "hostname rt\npassword s3cret\n"
    match = /password (\S+)/.match(text)
    expect(described_class.new(pattern: /password (\S+)/, replacement: 'password <x>').offsets(match)).to eq(21...27)
  end
end

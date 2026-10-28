# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/edgeos'
require 'glazed/redactor'

RSpec.describe Glazed::Dialects::Edgeos do
  it_behaves_like 'a dialect simulation', 'edgeos/er', transport: 'ssh'

  describe 'lines that are not secrets' do
    let(:redactor) { Glazed::Redactor.new(patterns: described_class.sensitive_patterns, mode: :remove) }

    it 'keeps public keys, route-map community references and password-related flags' do
      text = <<~EOS
        set system login user admin authentication public-keys k1 key 'AAAAC3NzaC1lZDI1NTE5AAAAIFAKE'
        set policy route-map IN rule 10 match community community-list '100'
        set policy community-list 100 rule 10 regex '_65535:0_'
        set service ssh disable-password-authentication
      EOS

      expect(redactor.call(text)).to eq(text)
    end

    it 'redacts only the secret and keeps the rest of the line' do
      text = "set protocols bgp 64512 neighbor 198.51.100.1 password 'abc123'\n"

      expect(redactor.call(text)).to eq("set protocols bgp 64512 neighbor 198.51.100.1 password [~REDACTED~]\n")
    end
  end
end

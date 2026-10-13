# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/base'

RSpec.describe Glazed::Dialects::Base do
  let(:parent) do
    Class.new(described_class) do
      prompt(/^parent#\s?$/)
      comment_prefix '! '
      filter_data { it.delete("\r") }
      filter_output { it.upcase }
      sensitive_pattern(/^secret (\S+)/) { it[1] }
      interact(/--More--/) { nil }
      communication(:telnet) { it.username_prompt = /login:/ }
      communication(:ssh, :telnet) { |config| config.post_login { nil } }
      runbook(:get) { it.command('show parent') }
    end
  end
  let(:child) do
    Class.new(parent) do
      filter_data { it.delete("\e") }
      sensitive_pattern(/^key (\S+)/) { it[1] }
      communication(:telnet) { it.password_prompt = /password:/ }
      runbook(:get) { it.command('show child') }
    end
  end

  it 'inherits the prompt and comment prefix' do
    expect(child.prompt_pattern).to eq(/^parent#\s?$/)
    expect(child.comment('a')).to eq("! a\n")
  end

  it 'lets a child replace the prompt without touching the parent' do
    child.prompt(/^child#\s?$/)
    expect([parent.prompt_pattern, child.prompt_pattern]).to eq([/^parent#\s?$/, /^child#\s?$/])
  end

  it 'accumulates lists from parent to child' do
    expect(child.data_filters.map { it.call("\r\ex") }).to eq(["\ex", "\rx"])
    expect(child.sensitive_patterns.map(&:pattern)).to eq([/^secret (\S+)/, /^key (\S+)/])
    expect(child.interactions.size).to eq(1)
    expect(parent.sensitive_patterns.size).to eq(1)
  end

  it 'applies communication blocks for the transport, parent first' do
    telnet = child.communication_config(:telnet)
    expect([telnet.username_prompt, telnet.password_prompt]).to eq([/login:/, /password:/])
    expect(telnet.post_login_hooks.size).to eq(1)
    expect(child.communication_config(:ssh).username_prompt).to be_nil
  end

  it 'replaces an inherited runbook' do
    expect(child.runbook_for(:get).steps.map(&:description)).to eq(['show child'])
    expect(parent.runbook_for(:get).steps.map(&:description)).to eq(['show parent'])
  end

  it 'raises NotImplementedError for an undeclared runbook or prompt' do
    expect { child.runbook_for(:put) }.to raise_error(NotImplementedError, /put/)
    expect { Class.new(described_class).prompt_pattern }.to raise_error(NotImplementedError, /prompt/)
  end

  it 'comments every line and drops trailing spaces of blank ones' do
    expect(Class.new(described_class).comment("a\n\nb")).to eq("# a\n#\n# b\n")
  end

  describe 'running a runbook' do
    let(:dialect) do
      Class.new(described_class) do
        prompt(/^rt1#\s?$/)
        filter_output { it.delete("\r") }
        runbook :get do |book|
          book.raw('model') { |run| run.vars[:model] = run.command('show model').output.strip }
          book.command('show version') { |result| comment(result.output) }
          book.command('show run')
          book.raw('tail') { |run| run.emit("# model #{run.vars[:model]}\n") }
        end
      end
    end
    let(:transport) do
      FakeTransport.new(responses: {
        'show model' => "mx960\r\nrt1#",
        'show version' => "1.0\r\nrt1#",
        'show run' => "hostname rt1\r\nrt1#",
      })
    end
    let(:node) { Glazed::Proto::V1::Node.new(name: 'rt1', params: {'a' => 'b'}, secrets: {'enable' => {value: 'e'}}) }
    let(:run) do
      Glazed::Dialect::Run.new(cli: Glazed::CliSession.new(transport:, prompt: dialect.prompt_pattern, timeout: 1), node:, dialect:)
    end

    it 'collects filtered output, comments and vars in step order' do
      expect(dialect.runbook_for(:get).execute(run)).to eq("# 1.0\nhostname rt1\n# model mx960\n")
    end

    it 'exposes node params and secrets' do
      expect(run.param('a')).to eq('b')
      expect(run.secret('enable')&.value).to eq('e')
      expect(run.secret('missing')).to be_nil
    end
  end
end

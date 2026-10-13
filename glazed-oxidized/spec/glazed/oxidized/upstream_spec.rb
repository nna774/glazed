# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'spec_helper'
require 'glazed/collector'
require 'glazed/redactor'
require 'yaml'

# Replays the model tests of the Oxidized source tree at OXIDIZED_SOURCE (spec/model/data, read the
# same way as its spec/model/model_helper.rb) with its own model files.
RSpec.describe 'Oxidized model tests', if: !ENV.fetch('OXIDIZED_SOURCE', '').empty? do
  # asa is left out: its simulated show version never shows a prompt the model matches.
  models = %w[aoscx arubainstant fsos garderos ios junos opnsense pfsense routeros]
  source = File.expand_path(ENV.fetch('OXIDIZED_SOURCE', '.'))
  data = File.join(source, 'spec', 'model', 'data')
  tests = ->(kind) { Dir[File.join(data, "*:*:#{kind}")].sort.map { File.basename(it).split(':').first(2) }.select { models.include?(it[0]) } }

  def undump(text) = "\"#{text}\"".undump

  def load_data(model, description, kind) = YAML.load_file(File.join(@data, "#{model}:#{description}:#{kind}"))

  # Builds the upstream model's dialect in place of any spec fixture by the same name.
  def dialect(model)
    dialect = Glazed::Oxidized::ModelDialect.build(Glazed::Oxidized::ModelBox.new(name: model, path: File.join(@source, 'lib', 'oxidized', 'model', "#{model}.rb")))
    stub_const("Glazed::Dialects::Oxidized#{model.split('_').map(&:capitalize).join}", dialect)
  end

  def collect(model, description, params: {})
    simulation = load_data(model, description, 'simulation.yaml')
    commands = simulation.fetch('commands').transform_values { undump(it) }
    # Oxidized's mock ignores what is sent on logout.
    logout = {'exit' => '', 'quit' => ''}
    device = if dialect(model).model_box.configured_input(:ssh)&.glazed_exec?
      FakeTransport.device(exec_responses: commands, responses: logout)
    else
      FakeTransport.device(greeting: undump(simulation.fetch('init_prompt')), responses: logout.merge(commands), echo: false)
    end
    stub_const('Glazed::Transports::Ssh', device)
    node = Glazed::Proto::V1::Node.new(name: 'example.com', dialect: "oxidized_#{model}", transport: 'ssh', username: 'admin', params:)
    Glazed::Collector.new(node:, timeout: 1).call
  end

  before do
    @source = source
    @data = data
  end

  it 'covers every selected model' do
    expect(tests.call('output.txt').map(&:first).uniq).to match_array(models)
  end

  tests.call('output.txt').each do |model, description|
    it "collects #{model} #{description} as Oxidized does" do
      expect(collect(model, description)).to eq(File.read(File.join(data, "#{model}:#{description}:output.txt")))
    end
  end

  tests.call('prompt.yaml').each do |model, description|
    it "detects #{model} #{description} prompts as Oxidized does" do
      prompts = load_data(model, description, 'prompt.yaml')
      prompt = dialect(model).prompt_pattern
      expect(Array(prompts['pass']).reject { prompt.match?(it) }).to be_empty
      expect(Array(prompts['fail']).select { prompt.match?(it) }).to be_empty
    end
  end

  tests.call('secret.yaml').each do |model, description|
    context "with #{model} #{description} secrets" do
      let(:secrets) { load_data(model, description, 'secret.yaml') }

      it 'removes them with remove_secret as Oxidized does' do
        removed = collect(model, description, params: {'remove_secret' => 'true'})
        expect(Array(secrets['pass']).reject { removed.match?(Regexp.new(it)) }).to be_empty
        expect(Array(secrets['fail']).select { removed.match?(Regexp.new(it)) }).to be_empty
      end

      it 'redacts every line remove_secret changes' do
        raw = collect(model, description)
        removed = collect(model, description, params: {'remove_secret' => 'true'})
        redacted = Glazed::Redactor.new(patterns: dialect(model).sensitive_patterns, mode: :remove).call(raw)
        hidden = raw.lines.zip(removed.lines).reject { |line, without| line == without }.map(&:first)
        expect(hidden).not_to be_empty
        expect(redacted.lines & hidden).to be_empty
        expect(Array(secrets['fail']).select { redacted.match?(Regexp.new(it)) }).to be_empty
      end
    end
  end
end

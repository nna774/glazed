# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/config'

RSpec.describe Glazed::Config do
  def parse(rule)
    config = {
      inventory: [{inline: {nodes: [{name: 'rt1', dialect: 'ios'}]}}],
      workflows: {backup: {steps: [{name: 'fetch', fetch: {output: 'raw', storage: 'raw'}}]}},
      storages: {raw: {memory: {}}},
      orchestrator: {state: {sqlite: {path: 'state.sqlite3'}}, workflows: {backup: {schedule_rules: [rule]}}},
    }
    described_class.parse(JSON.generate(config), origin: 'test.json')
  end

  describe 'schedule_rules' do
    it 'accepts a rule with a match and a schedule' do
      config = parse(match: {name_regexp: '.*\.venue'}, schedule: {interval: '60s'})
      expect(config.orchestrator.workflows['backup'].schedule_rules.size).to eq(1)
    end

    it 'rejects a rule that sets neither schedule nor debounce' do
      expect { parse(match: {names: ['rt1']}) }.to raise_error(Glazed::InvalidMessage, /set schedule, debounce or both/)
    end

    it 'rejects a match without criteria' do
      expect { parse(match: {}, schedule: {interval: '60s'}) }.to raise_error(Glazed::InvalidMessage, /at least one of names, groups and name_regexp/)
    end

    it 'rejects a name_regexp that does not compile' do
      expect { parse(match: {name_regexp: '('}, schedule: {interval: '60s'}) }
        .to raise_error(Glazed::InvalidMessage, /workflows\.backup\.schedule_rules\[0\]\.match\.name_regexp/)
    end
  end

  describe 'durations' do
    def parse_step(fetch)
      config = {
        inventory: [{inline: {nodes: [{name: 'rt1', dialect: 'ios'}]}}],
        workflows: {backup: {steps: [{name: 'fetch', fetch: {output: 'raw', storage: 'raw', **fetch}}]}},
        storages: {raw: {memory: {}}},
      }
      described_class.parse(JSON.generate(config), origin: 'test.json')
    end

    it 'reads ProtoJSON durations' do
      expect(parse_step(timeout: '1.5s').workflows['backup'].steps.first.fetch.timeout.to_f).to eq(1.5)
    end

    it 'rejects a negative duration' do
      expect { parse_step(timeout: '-1s') }.to raise_error(Glazed::InvalidMessage, /timeout/)
    end

    it 'rejects the removed _seconds field' do
      expect { parse_step(timeout_seconds: 60) }.to raise_error(Glazed::Error, /timeout_seconds/)
    end
  end
end

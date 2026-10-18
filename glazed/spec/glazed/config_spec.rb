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
      config = parse(match: {name_regexp: '.*\.venue'}, schedule: {interval_seconds: 60})
      expect(config.orchestrator.workflows['backup'].schedule_rules.size).to eq(1)
    end

    it 'rejects a rule that sets neither schedule nor debounce' do
      expect { parse(match: {names: ['rt1']}) }.to raise_error(Glazed::InvalidMessage, /set schedule, debounce or both/)
    end

    it 'rejects a match without criteria' do
      expect { parse(match: {}, schedule: {interval_seconds: 60}) }.to raise_error(Glazed::InvalidMessage, /at least one of names, groups and name_regexp/)
    end

    it 'rejects a name_regexp that does not compile' do
      expect { parse(match: {name_regexp: '('}, schedule: {interval_seconds: 60}) }
        .to raise_error(Glazed::InvalidMessage, /workflows\.backup\.schedule_rules\[0\]\.match\.name_regexp/)
    end
  end
end

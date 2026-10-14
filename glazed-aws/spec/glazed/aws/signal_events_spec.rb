# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/aws/signal_events'

RSpec.describe Glazed::Aws::SignalEvents do
  let(:events) { [] }

  def extract(input) = described_class.extract(input, listener: ->(event) { events << event }).map(&:to_h)

  def eventbridge(detail)
    {'version' => '0', 'id' => 'e1', 'detail-type' => 'glazed signal', 'source' => 'syslog.example', 'time' => '2026-10-14T04:00:20Z', 'detail' => detail}
  end

  it 'reads nothing from scheduled or empty input' do
    expect(extract(nil)).to eq([])
    expect(extract({})).to eq([])
  end

  it 'reads the detail of an EventBridge event, defaulting source and time to the event' do
    expect(extract(eventbridge({'node' => 'sw1'}))).to eq([{node: 'sw1', source: 'syslog.example', received_at: {seconds: Time.utc(2026, 10, 14, 4, 0, 20).to_i}}])
    expect(extract(eventbridge({'node' => 'sw1', 'source' => 'syslog'})).first).to include(source: 'syslog')
  end

  it 'reads signals given in the input' do
    expect(extract({'signals' => [{'all_nodes' => true, 'workflows' => ['backup'], 'source' => 'daily', 'immediate' => true}]}))
      .to eq([{all_nodes: true, workflows: ['backup'], source: 'daily', immediate: true}])
  end

  it 'reads SQS messages from an EventBridge Pipe holding signals or EventBridge events' do
    messages = [
      {'messageId' => 'm1', 'body' => JSON.generate({'node' => 'sw1', 'source' => 'trap'}), 'attributes' => {'SentTimestamp' => '1800000000500'}},
      {'messageId' => 'm2', 'body' => JSON.generate(eventbridge({'node' => 'rt1'}))},
    ]
    expect(extract(messages)).to eq([
      {node: 'sw1', source: 'trap', received_at: {seconds: 1_800_000_000, nanos: 500_000_000}},
      {node: 'rt1', source: 'syslog.example', received_at: {seconds: Time.utc(2026, 10, 14, 4, 0, 20).to_i}},
    ])
  end

  it 'skips entries that do not decode or validate, keeping the others' do
    messages = [
      {'messageId' => 'm1', 'body' => 'not json'},
      {'messageId' => 'm2', 'body' => JSON.generate({'node' => 'sw1'})},
      {'messageId' => 'm3', 'body' => JSON.generate({'node' => 'sw1', 'source' => 'trap', 'colour' => 'red'})},
      {'messageId' => 'm4'},
      {'messageId' => 'm5', 'body' => JSON.generate({'node' => 'rt1', 'source' => 'trap'})},
    ]
    expect(extract(messages).map { it[:node] }).to eq(['rt1'])
    expect(events.size).to eq(4)
    expect(events).to all(include(level: 'error', message: start_with('signal skipped: ')))
  end
end

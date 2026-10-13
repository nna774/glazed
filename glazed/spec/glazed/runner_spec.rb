# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/runner'

RSpec.describe Glazed::Runner do
  # Per-node step appending its name to a "trail" param; fails for nodes named in fail_for.
  def node_step(name, fail_for: [])
    Class.new(Glazed::Steps::NodeStep) do
      define_method(:call) do |state|
        raise Glazed::Error, "#{state.node.name} broke" if fail_for.include?(state.node.name)

        copy = Glazed::Proto::V1::NodeState.decode(Glazed::Proto::V1::NodeState.encode(state))
        copy.node.params['trail'] = [copy.node.params['trail'], name].compact.join(',')
        copy
      end
    end.new(name:)
  end

  def batch_step(name, seen)
    Class.new(Glazed::Steps::BatchStep) do
      define_method(:call) do |batch|
        seen << batch.nodes.map { it.node.name }
        batch
      end
    end.new(name:)
  end

  let(:nodes) { %w[a b c].map { Glazed::Proto::V1::Node.new(name: it) } }
  let(:events) { [] }

  it 'runs per-node steps, then batch steps with the nodes that completed them' do
    seen = []
    workflow = Glazed::Workflow.new(steps: [node_step('one'), node_step('two', fail_for: ['b']), batch_step('batch', seen), node_step('three')])
    result = described_class.new(workflow:, jobs: 2, listener: ->(event) { events << event }).call(nodes)

    expect(result.states.map { [it.node.name, it.node.params['trail']] }).to eq([%w[a one,two,three], %w[c one,two,three]])
    expect(seen).to eq([%w[a c]])
    expect(result.failures.map { [it.node.name, it.step, it.error.message] }).to eq([['b', 'two', 'b broke']])
    expect(events).to include({level: 'error', step: 'two', node: 'b', error: 'Glazed::Error', message: 'b broke'})
    expect(events).to include({level: 'info', step: 'batch', nodes: 2, message: 'done'})
  end

  it 'propagates batch step failures' do
    failing = Class.new(Glazed::Steps::BatchStep) { define_method(:call) { |_batch| raise Glazed::Error, 'push rejected' } }.new(name: 'publish')
    expect { described_class.new(workflow: Glazed::Workflow.new(steps: [failing]), jobs: 1).call(nodes) }
      .to raise_error(Glazed::Error, 'push rejected')
  end

  it 'reports where unfinished nodes are when interrupted' do
    release = Thread::Queue.new
    stuck = Class.new(Glazed::Steps::NodeStep) do
      define_method(:call) do |_state|
        Thread.pass until Thread.main.status == 'sleep'
        Thread.main.raise(Interrupt)
        release.pop
      end
    end.new(name: 'fetch')
    runner = described_class.new(workflow: Glazed::Workflow.new(steps: [stuck]), jobs: 1, listener: ->(event) { events << event })

    expect { runner.call(nodes.first(1)) }.to raise_error(Interrupt)
    expect(events).to contain_exactly(include(level: 'error', node: 'a', message: 'interrupted', backtrace: include(/in 'Thread::Queue#pop'/)))
  ensure
    release&.close
  end
end

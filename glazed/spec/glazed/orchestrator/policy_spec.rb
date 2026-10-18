# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/orchestrator'

RSpec.describe Glazed::Orchestrator::Policy do
  let(:t0) { Time.at(1_800_000_000) }
  let(:debounce) { Glazed::Proto::V1::Debounce.new(delay: {seconds: 60}, max_wait: {seconds: 300}) }
  let(:schedule) { Glazed::Proto::V1::Schedule.new(interval: {seconds: 3600}, retry_interval: {seconds: 600}) }
  let(:random) { Random.new(1) }

  def ts(time) = Google::Protobuf::Timestamp.from_time(time)
  def record(**fields) = Glazed::Proto::V1::NodeSchedule.new(workflow: 'backup', node: 'rt1', **fields)
  def signal_at(time, **fields) = Glazed::Proto::V1::Signal.new(node: 'rt1', source: 'syslog', received_at: ts(time), **fields)
  def apply(current, time, **fields) = described_class.signal(current, signal_at(time, **fields), workflow: 'backup', now: time, debounce:)

  describe '.discovered' do
    it 'is due now without jitter' do
      expect(described_class.discovered('backup', 'rt1', now: t0, schedule: nil, random:).to_h)
        .to include(workflow: 'backup', node: 'rt1', due_reason: 'inventory', due_at: {seconds: t0.to_i})
    end

    it 'spreads nodes over the jitter' do
      due = described_class.discovered('backup', 'rt1', now: t0, schedule: Glazed::Proto::V1::Schedule.new(jitter: {seconds: 30}), random:).due_at.to_time
      expect(due).to be_between(t0, t0 + 30)
    end
  end

  describe '.signal' do
    it 'creates a record due after the delay' do
      result = apply(nil, t0)
      expect(result.due_at.to_time).to eq(t0 + 60)
      expect(result.due_reason).to eq('syslog')
      expect(result.signal_window_started_at.to_time).to eq(t0)
    end

    it 'pushes the due date back with each signal' do
      result = apply(apply(apply(nil, t0), t0 + 30), t0 + 50)
      expect(result.due_at.to_time).to eq(t0 + 110)
      expect(result.signal_window_started_at.to_time).to eq(t0)
    end

    it 'caps the delay at the maximum wait after the first signal' do
      result = (0..280).step(40).inject(nil) { |current, offset| apply(current, t0 + offset) }
      expect(result.due_at.to_time).to eq(t0 + 300)
    end

    it 'keeps an earlier scheduled run' do
      result = apply(record(due_at: ts(t0 + 10), scheduled_at: ts(t0 + 10), due_reason: 'schedule'), t0)
      expect([result.due_at.to_time, result.due_reason]).to eq([t0 + 10, 'schedule'])
    end

    it 'replaces a later scheduled run' do
      expect(apply(record(due_at: ts(t0 + 3000), scheduled_at: ts(t0 + 3000)), t0).due_at.to_time).to eq(t0 + 60)
    end

    it 'runs immediately when asked' do
      expect(apply(record(due_at: ts(t0 + 3000)), t0, immediate: true).due_at.to_time).to eq(t0)
    end

    it 'schedules a run after the current one for a signal received while running' do
      running = record(due_at: ts(t0 - 100), last_started_at: ts(t0 - 10), lease_owner: 'x', lease_until: ts(t0 + 3600),
        signal_window_started_at: ts(t0 - 200))
      result = apply(running, t0)
      expect(result.due_at.to_time).to eq(t0 + 60)
      expect(result.signal_window_started_at.to_time).to eq(t0)
    end

    it 'uses the current time for a signal without a reception time' do
      signal = Glazed::Proto::V1::Signal.new(node: 'rt1', source: 'manual')
      expect(described_class.signal(nil, signal, workflow: 'backup', now: t0, debounce: nil).due_at.to_time).to eq(t0 + 60)
    end
  end

  describe '.claim' do
    it 'leases a due node' do
      result = described_class.claim(record(due_at: ts(t0)), owner: 'me', now: t0, lease_seconds: 600)
      expect(result.to_h).to include(lease_owner: 'me', lease_until: {seconds: t0.to_i + 600}, last_started_at: {seconds: t0.to_i})
    end

    it 'leaves a node not yet due or leased to another' do
      future = record(due_at: ts(t0 + 1))
      leased = record(due_at: ts(t0), lease_owner: 'other', lease_until: ts(t0 + 1))
      expect(described_class.claim(future, owner: 'me', now: t0, lease_seconds: 600)).to equal(future)
      expect(described_class.claim(leased, owner: 'me', now: t0, lease_seconds: 600)).to equal(leased)
      expect(described_class.claim(nil, owner: 'me', now: t0, lease_seconds: 600)).to be_nil
    end

    it 'takes over an expired lease' do
      expired = record(due_at: ts(t0 - 10), lease_owner: 'other', lease_until: ts(t0))
      expect(described_class.claim(expired, owner: 'me', now: t0, lease_seconds: 600).lease_owner).to eq('me')
    end
  end

  describe '.schedule_for and .debounce_for' do
    let(:orchestration) do
      Glazed::Proto::V1::Orchestration.new(
        schedule: {interval: {seconds: 900}},
        debounce: {delay: {seconds: 10}},
        schedule_rules: [
          {match: {groups: ['venue'], name_regexp: 'es-.*'}, schedule: {interval: {seconds: 1}}},
          {match: {groups: ['venue']}, debounce: {delay: {seconds: 20}}},
          {match: {names: ['er-01']}, schedule: {interval: {seconds: 2}}, debounce: {delay: {seconds: 30}}},
        ],
      )
    end

    def node(name, group) = Glazed::Proto::V1::Node.new(name:, group:)

    it 'uses the first rule that matches and sets the field' do
      expect(described_class.schedule_for(orchestration, node('es-01', 'venue')).interval.seconds).to eq(1)
      expect(described_class.debounce_for(orchestration, node('es-01', 'venue')).delay.seconds).to eq(20)
    end

    it 'requires every criterion of a rule to match' do
      expect(described_class.schedule_for(orchestration, node('es-01', 'hnd')).interval.seconds).to eq(900)
      expect(described_class.schedule_for(orchestration, node('xes-01', 'venue')).interval.seconds).to eq(900)
    end

    it 'skips a matching rule that does not set the field' do
      expect(described_class.schedule_for(orchestration, node('er-01', 'venue')).interval.seconds).to eq(2)
      expect(described_class.debounce_for(orchestration, node('er-01', 'venue')).delay.seconds).to eq(20)
      expect(described_class.debounce_for(orchestration, node('er-01', 'hnd')).delay.seconds).to eq(30)
    end

    it 'uses the workflow settings when no rule matches' do
      expect(described_class.schedule_for(orchestration, node('br-01', 'hnd')).interval.seconds).to eq(900)
      expect(described_class.debounce_for(orchestration, node('br-01', 'hnd')).delay.seconds).to eq(10)
    end
  end

  describe '.completed' do
    let(:claimed) do
      record(due_at: ts(t0), due_reason: 'syslog', signal_window_started_at: ts(t0 - 60), last_started_at: ts(t0),
        lease_owner: 'me', lease_until: ts(t0 + 600), consecutive_failures: 2)
    end

    def complete(current, error: nil, finished_at: t0 + 30)
      described_class.completed(current, owner: 'me', finished_at:, error:, schedule:, random:)
    end

    it 'schedules the next run after the interval and releases the lease' do
      result = complete(claimed)
      expect(result.to_h).to include(due_at: {seconds: t0.to_i + 3630}, scheduled_at: {seconds: t0.to_i + 3630}, due_reason: 'schedule',
        last_finished_at: {seconds: t0.to_i + 30})
      expect(result).to have_attributes(last_failed: false, consecutive_failures: 0, lease_owner: '', lease_until: nil)
      expect(result.signal_window_started_at).to be_nil
    end

    it 'retries a failed run after the retry interval' do
      result = complete(claimed, error: 'fetch: timeout')
      expect(result.to_h).to include(due_at: {seconds: t0.to_i + 630}, due_reason: 'retry', last_failed: true,
        last_error: 'fetch: timeout', consecutive_failures: 3)
    end

    it 'keeps the due date of a signal received during the run' do
      during = apply(claimed, t0 + 10)
      result = complete(during)
      expect(result.due_at.to_time).to eq(t0 + 70)
      expect(result.signal_window_started_at.to_time).to eq(t0 + 10)
    end

    it 'leaves a record leased to another orchestrator' do
      other = record(due_at: ts(t0), lease_owner: 'other')
      expect(complete(other)).to equal(other)
    end
  end

  describe '.released' do
    it 'drops the lease only' do
      result = described_class.released(record(due_at: ts(t0), lease_owner: 'me', lease_until: ts(t0 + 600)), owner: 'me')
      expect(result.lease_owner).to eq('')
      expect(result.due_at.to_time).to eq(t0)
    end
  end
  describe '.arm' do
    def wakeup(owner, wake_at, expires_at = wake_at + 3600) = Glazed::Proto::V1::Wakeup.new(owner:, wake_at: ts(wake_at), expires_at: ts(expires_at))

    def arm(record, token: 'me', next_due: t0 + 60, cycle: 0, now: t0, alive: ->(_token) { true })
      described_class.arm(record, token:, next_due:, now:, gap: 30, grace: 3600, cycle:, max_cycles: 3, alive:)
    end

    it 'waits for the next due node when nobody waits' do
      record, wake = arm(nil)
      expect(wake).to eq(t0 + 60)
      expect(record.to_h).to include(owner: 'me', wake_at: {seconds: t0.to_i + 60}, expires_at: {seconds: t0.to_i + 3660})
    end

    it 'runs a node due already right away on the first cycle' do
      expect(arm(nil, next_due: t0 - 5).last).to eq(t0)
    end

    it 'waits at least the gap on later cycles' do
      expect(arm(nil, next_due: t0 + 5, cycle: 1).last).to eq(t0 + 30)
    end

    it 'ends when another live waiter wakes earlier or at the same time' do
      other = wakeup('other', t0 + 60)
      expect(arm(other)).to eq([other, nil])
      expect(arm(other, next_due: t0 + 100)).to eq([other, nil])
    end

    it 'takes over from a waiter waking later' do
      record, wake = arm(wakeup('other', t0 + 600))
      expect([record.owner, wake]).to eq(['me', t0 + 60])
    end

    it 'takes over from a waiter presumed lost' do
      expect(arm(wakeup('other', t0 - 10, t0)).first.owner).to eq('me')
    end

    it 'takes over from a waiter whose execution ended before its record expires' do
      checked = []
      record, wake = arm(wakeup('other', t0 - 10), alive: ->(token) { checked << token && false })
      expect([record.owner, wake, checked]).to eq(['me', t0 + 60, ['other']])
    end

    it 'checks liveness only of a waiter it would defer to' do
      alive = ->(_token) { raise 'not expected' }
      expect(arm(wakeup('other', t0 + 600), alive:).first.owner).to eq('me')
      expect(arm(wakeup('me', t0), alive:, cycle: 1).first.owner).to eq('me')
    end

    it 'moves its own wake time later' do
      record, wake = arm(wakeup('me', t0), next_due: t0 + 600, cycle: 1)
      expect([record.owner, wake]).to eq(['me', t0 + 600])
    end

    it 'gives up its record when nothing is due, or after the last cycle' do
      expect(arm(wakeup('me', t0), next_due: nil)).to eq([nil, nil])
      expect(arm(wakeup('me', t0), cycle: 3)).to eq([nil, nil])
      other = wakeup('other', t0)
      expect(arm(other, next_due: nil)).to eq([other, nil])
    end
  end
end

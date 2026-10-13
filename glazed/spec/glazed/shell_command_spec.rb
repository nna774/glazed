# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/shell_command'

RSpec.describe Glazed::ShellCommand do
  def run(command, env: {}, stdin: '', timeout: 5) = described_class.new(run: command, env:, stdin:, timeout:).call

  it 'pipes stdin through the command and returns stdout' do
    expect(run('tr a-z A-Z', stdin: "hostname rt1\n")).to eq("HOSTNAME RT1\n")
  end

  it 'adds the given environment' do
    expect(run('printf %s "$GLAZED_STEP"', env: {'GLAZED_STEP' => 'normalize'})).to eq('normalize')
  end

  it 'raises Failed with the exit status and stderr' do
    expect { run('echo broken >&2; exit 3') }.to raise_error(described_class::Failed, /exited with 3: broken/)
  end

  it 'tolerates a command that does not read stdin' do
    expect(run('true', stdin: 'x' * 1_000_000)).to eq('')
  end

  it 'kills the whole process group on timeout' do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, 'survived')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { run("(sleep 1; touch #{marker}) & sleep 30", timeout: 0.2) }.to raise_error(Glazed::TimeoutError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      sleep 1.5
      expect(File.exist?(marker)).to be(false)
    end
  end
end

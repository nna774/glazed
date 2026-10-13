# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'yaml'

# Device capture in Oxidized's spec/model/data simulation format (read the same
# way as its spec/model/model_helper.rb, Apache License 2.0): an initial
# prompt and, per command, the raw response including the echoed command and
# the trailing prompt. Escapes such as \x20 are interpreted.
class Simulation
  ROOT = File.expand_path('../fixtures/dialects', __dir__)

  def self.load(name) = new(name)

  def initialize(name)
    @name = name
    data = YAML.load_file(File.join(ROOT, "#{name}.yaml"))
    @init_prompt = undump(data.fetch('init_prompt'))
    @commands = data.fetch('commands').to_h { |command, response| [command, undump(response)] }
    @secrets = data.fetch('secrets', [])
  end

  attr_reader :commands, :init_prompt, :secrets

  # Device answering on an interactive shell.
  def shell_device(**options) = FakeTransport.device(greeting: init_prompt, responses: commands, echo: false, **options)

  # Device answering on exec channels, which carry neither echo nor prompt.
  def exec_device
    FakeTransport.device(exec_responses: commands.transform_values { it.lines[1...-1].join })
  end

  def expected(kind) = File.read(expected_path(kind))

  def write_expected(kind, text) = File.write(expected_path(kind), text)

  private def expected_path(kind) = File.join(ROOT, "#{@name}.#{kind}.txt")

  private def undump(text) = "\"#{text}\"".undump
end

# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/routeros.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # MikroTik RouterOS. Ported from oxidized's routeros model.
    #
    # Node params: "routeros_hide_sensitive" set to "true" collects `/export hide-sensitive`.
    # Otherwise RouterOS 7 and later run `/export show-sensitive`, and older versions `/export`.
    class Routeros < Base
      # A key=value value, either quoted or bare.
      VALUE = /(?:"((?:[^"\\]|\\.)*)"|([^\s"]\S*))/ #: Regexp

      prompt(/\[\w+@\S+(\s+\S+)*\]\s?>\s?$/)
      comment_prefix '# '

      # Cursor movements also appear, such as before the prompt.
      filter_output { it.gsub(/\x1B\[[0-9;?]*[A-Za-z]/, '') }
      filter_output { it.gsub(/^\r+(.+)/, '\1').gsub(/([^\r]*)\r+$/, '\1') }

      sensitive_pattern(
        /(?<![\w.-])[\w.-]*(?:password|passphrase|secret|pre-shared-key|preshared-key|private-key|psk|md5-key|auth-key|authentication-key|protection-key|static-key-\d|trap-community)=#{VALUE}/,
      ) { it[1] || it[2] }
      # Community names follow `name=`, one section at a time. \G continues from the previous match.
      sensitive_pattern(
        /(?:^\/snmp community\n|\G(?<=\S)[^\n]*\n)(?:(?:add|set)[^\n]*\n)*?(?:add|set) [^\n]*?(?<=\s)name=#{VALUE}/,
      ) { it[1] || it[2] }

      runbook :get do |book|
        book.command('/system resource print') do |result|
          comment(result.output.each_line.grep(/(version|factory-software|total-memory|cpu|cpu-count|total-hdd-space|architecture-name|board-name|platform):/).join)
        end
        book.raw('/system package update print') do |run|
          line = run.command('/system package update print').output.each_line.grep(/installed-version:\s|current-version:\s/).first
          next unless line

          run.vars[:ros_version] = line[/:\s*(\d+)/, 1]&.to_i
          run.emit(comment(line))
        end
        book.command('/system history print without-paging') { comment(it.output) }
        book.raw('/export') do |run|
          line = if run.param('routeros_hide_sensitive') == 'true'
            '/export hide-sensitive'
          elsif (version = run.vars[:ros_version]).is_a?(Integer) && version >= 7
            '/export show-sensitive'
          else
            '/export'
          end
          run.emit(export(run.command(line).output))
        end
      end

      communication :telnet do |config|
        config.username_prompt = /^Login:/
        config.password_prompt = /^Password:/
        config.pre_logout { |run| run.cli.write("quit\n") }
      end

      communication :ssh do |config|
        config.exec = true
      end

      class << self
        # Drops the lines of `/export` that change without configuration changes
        # and joins the lines RouterOS wraps with a trailing backslash.
        #
        # @param output [String] output of `/export`
        # @return [String] the configuration, ending with a newline
        #: (String output) -> String
        def export(output)
          config = output
                   .gsub(/\\\r?\n\s+/, '')
                   .gsub("# inactive time\n", '')
                   .gsub(/# received packet from \S+ bad format\n/, '')
                   .gsub("# poe-out status: short_circuit\n", '')
                   .gsub("# Firmware upgraded successfully, please reboot for changes to take effect!\n", '')
                   .gsub(/# \S+ not ready\n/, '')
          lines = config.split("\n").reject { it.match?(%r{^#\s\w{3}/\d{2}/\d{4}.*$}) || it.match?(/^#\s\d{4}-\d{2}-\d{2}.*$/) }
          "#{lines.join("\n")}\n"
        end
      end
    end
  end
end

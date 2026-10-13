# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/ios.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # Cisco IOS and IOS XE. Ported from oxidized's ios model.
    #
    # Node params: "ios_rbac" set to "true" collects `show running-config view full`.
    # Node secrets: "enable" is sent as the enable password; without it, param
    # "enable" set to "true" runs `enable` without one.
    class Ios < Base
      prompt(/^([\w.@()-]+[#>]\s?)$/)
      comment_prefix '! '

      # Commands some platforms lack leave an error behind.
      filter_output { it.gsub(/^% Invalid input detected at '\^' marker\.$|^\s+\^$/, '') }

      sensitive_pattern(/^snmp-server community (\S+)/) { it[1] }
      # SNMPv3 hosts carry a user name, not a community.
      sensitive_pattern(/^snmp-server host (?!.* version 3 )\S+(?> vrf \S+)?(?> informs?| traps)?(?> version (?:1|2c))? +(\S+)/) { it[1] }
      sensitive_pattern(/^username .+ (?:password|secret) \d (.+)$/) { it[1] }
      sensitive_pattern(/^enable (?:password|secret)(?: level \d+)? \d (.+)$/) { it[1] }
      sensitive_pattern(/^ +(?:password|secret) (?:\d )?(\S+)/) { it[1] }
      sensitive_pattern(/^.*wpa-psk ascii \d (\S+)/) { it[1] }
      sensitive_pattern(/^.*key 7 (\d.+)$/) { it[1] }
      sensitive_pattern(/^tacacs-server (?:.+ )?key (?:\d )?(.+)$/) { it[1] }
      sensitive_pattern(/^crypto isakmp key (\S+) /) { it[1] }
      sensitive_pattern(/^ +ip ospf message-digest-key \d+ md5 (?:\d )?(.+)$/) { it[1] }
      sensitive_pattern(/^ +ip ospf authentication-key (?:\d )?(.+)$/) { it[1] }
      sensitive_pattern(/^ +neighbor \S+ password (?:\d )?(.+)$/) { it[1] }
      sensitive_pattern(/^ +vrrp \d+ authentication text (.+)$/) { it[1] }
      sensitive_pattern(/^ +standby \d+ authentication (?!md5 )(.{1,8})$/) { it[1] }
      sensitive_pattern(/^ +standby \d+ authentication md5 key-string (?:\d )?(.+?)(?: timeout \d+)?$/) { it[1] }
      sensitive_pattern(/^ +key-string (?:\d )?(.+)$/) { it[1] }
      sensitive_pattern(/^(?:tacacs|radius) server [^\n]+\n(?: +[^\n]+\n)*? +key (?:\d+ )?(\S+)/) { it[1] }
      sensitive_pattern(/^ +ppp (?:chap|pap) password \d (.+)$/) { it[1] }
      sensitive_pattern(/^ +security wpa psk set-key (?:ascii|hex) \d (.+)$/) { it[1] }
      sensitive_pattern(/^ +dot1x username \S+ password \d (.+)$/) { it[1] }
      sensitive_pattern(/^ +mgmtuser username \S+ password \d (.*) secret \d /) { it[1] }
      sensitive_pattern(/^ +mgmtuser username \S+ password \d .* secret \d (.*)$/) { it[1] }
      sensitive_pattern(/^ +client \S+ server-key \d (.+)$/) { it[1] }
      sensitive_pattern(/^ +domain-password (\S+)/) { it[1] }
      sensitive_pattern(/^ +pre-shared-key (.+)$/) { it[1] }

      runbook :get do |book|
        book.command('show version') { comment(version_summary(it.output)) }
        book.command('show vtp status') do |result|
          vtp = result.output.gsub(/^\s*\n/, '').gsub(/Configuration last modified by.*\n/, '')
          comment("#{vtp.gsub(/^/, 'VTP: ')}\n")
        end
        book.command('show inventory') { comment(it.output) }
        book.raw('show running-config') do |run|
          line = run.param('ios_rbac') == 'true' ? 'show running-config view full' : 'show running-config'
          run.emit(running_config(run.command(line).output))
        end
      end

      communication :telnet do |config|
        config.username_prompt = /^Username:/i
        config.password_prompt = /^Password:/i
      end

      communication :ssh, :telnet do |config|
        config.post_login do |run|
          if (enable = run.secret('enable'))
            run.cli.write("enable\n")
            run.cli.expect(/^[pP]assword:/)
            run.cli.write("#{enable.value}\n")
            run.cli.expect(run.cli.prompt)
          elsif run.param('enable') == 'true'
            run.cli.command('enable')
          end
          run.cli.command('terminal length 0')
          run.cli.command('terminal width 0')
        end
        config.pre_logout { |run| run.cli.write("exit\n") }
      end

      class << self
        # Summarises `show version` into stable facts, as oxidized does.
        #
        # @param output [String] output of `show version`
        # @return [String] summary lines, ending with a blank line
        #: (String output) -> String
        def version_summary(output)
          lines = output.lines
          facts = lines.first(1)
          lines.each_with_index do |line, index|
            facts.concat(version_facts(line, lines[index + 1], lines[index + 2]))
          end
          facts << "\n"
          facts.join("\n")
        end

        # Cleans `show running-config` of lines that change without configuration changes.
        #
        # @param output [String] output of `show running-config`
        # @return [String] the configuration
        #: (String output) -> String
        def running_config(output)
          config = output
                   .sub(/\A\s*Building configuration\.\.\.\n\s*\n?/, '')
                   .sub(/^Current configuration : [^\n]*\n/, '')
          config = config.each_line.reject do |line|
            line.start_with?('ntp clock-period ') ||
              (line.match?(/^! (Last|No) configuration change (at|since).*/) && !line.match?(/\d+\sby\s\S+$/))
          end.join
          config
            .gsub(/^ tunnel mpls traffic-eng bandwidth[^\n]*\n*((?: [^\n]*\n*)*tunnel mpls traffic-eng auto-bw)/m, '\1')
            .gsub(/^(\s+expression) \d+$/, '\1 <value removed>')
        end

        # @param line [String] a line of `show version`
        # @param next_line [String, nil] the line after it
        # @param line_after [String, nil] the line after that
        # @return [Array<String>] facts found on the line
        #: (String line, String? next_line, String? line_after) -> Array[String]
        private def version_facts(line, next_line, line_after)
          slave = (slot = line[/^Slave in slot (\d+) is running/, 1]) ? ' Slave:' : ''
          slave_slot = slot ? ", slot #{slot}" : ''
          facts = [] #: Array[String]
          if (m = line.match(/^Compiled (.*)$/))
            facts << "Image:#{slave} Compiled: #{m[1]}"
          end
          if (m = line.match(/^(?:Cisco )?IOS .* Software,? \(([A-Za-z0-9_-]*)\), .*Version\s+(.*)$/))
            facts << "Image:#{slave} Software: #{m[1]}, #{m[2]}"
          end
          if (m = line.match(/^ROM: (IOS \S+ )?(System )?Bootstrap.*(Version.*)$/))
            facts << "ROM Bootstrap: #{m[3]}"
          end
          if (m = line.match(/^BOOTFLASH: .*(Version.*)$/))
            facts << "BOOTFLASH: #{m[1]}"
          end
          if (m = line.match(/^(\d+[kK]) bytes of (non-volatile|NVRAM)/))
            facts << "Memory: nvram #{m[1]}"
          end
          if (m = line.match(/^(\d+[kK]) bytes of (flash memory|flash internal|processor board System flash|ATA CompactFlash)/i))
            facts << "Memory: flash #{m[1]}"
          end
          if (m = line.match(/^(\d+[kK]) bytes of (Flash|ATA)?.*PCMCIA .*(slot|disk) ?(\d)/i))
            facts << "Memory: pcmcia #{m[2]} #{m[3]}#{m[4]} #{m[1]}"
          end
          if (m = line.match(/(\S+(?:\sseries)?)\s+(?:\(([\S ]+)\)\s+processor|\(revision[^)]+\)).*\s+with (\S+k) bytes/i))
            cpu = m[2]
            facts << "Chassis type:#{slave} #{m[1]}"
            facts << "Memory:#{slave} main #{m[3]}"
            if (id = next_line&.match(/processor board id (\S+)/i))
              facts << "Processor ID: #{id[1]}"
            end
            cpu_extra = if line_after&.match?(/(cpu at |processor: |#{cpu} processor,)/i)
              line_after.gsub('implementation', 'impl').gsub(/^/, ', ').chomp
            else
              ''
                        end
            facts << "CPU:#{slave} #{cpu}#{cpu_extra}#{slave_slot}"
          end
          if (m = line.match(/^System image file is "([^"]*)"$/))
            facts << "Image: #{m[1]}"
          end
          facts
        end
      end
    end
  end
end

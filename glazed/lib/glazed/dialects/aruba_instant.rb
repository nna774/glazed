# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/arubainstant.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # Aruba Instant (IAP and Instant virtual controller). Ported from oxidized's arubainstant model.
    #
    # Node secrets: "enable" is sent as the enable password; without it, param
    # "enable" set to "true" runs `enable` without one.
    class ArubaInstant < Base
      # Access levels of `mgmt-user` on Instant virtual controllers and Mobility Access Switches.
      MGMT_ROLES = 'root|guest-provisioning|network-operations|read-only|location-api-mgmt' #: String

      # The prompt gains a leading space while a core file is present.
      prompt(/^ ?[\w:.@-]+[#>] $/)
      comment_prefix '# '

      sensitive_pattern(/ipsec (\S+)$/) { it[1] }
      sensitive_pattern(/community (\S+)$/) { it[1] }
      sensitive_pattern(/^\s*snmp-server host [\d.]+ version 2c (\S+)/) { it[1] }
      sensitive_pattern(/^\s*snmpv3-user .*?auth-pass (\S+)/) { it[1] }
      sensitive_pattern(/^\s*snmpv3-user .*?priv-pass (\S+)/) { it[1] }
      sensitive_pattern(/^\s*mgmt-user \S+ (?:#{MGMT_ROLES}) (\S+)$/) { it[1] }
      sensitive_pattern(/^\s*mgmt-user \S+ (?!(?:#{MGMT_ROLES}) )(\S+)(?: (?:read-only|guest-mgmt))?$/) { it[1] }
      sensitive_pattern(/key (\S+)$/) { it[1] }
      sensitive_pattern(/^\s*(?:\S+-)?(?:passwd|passphrase|psk|secret|password|passwords) (\S+)$/) { it[1] }
      sensitive_pattern(/^\s*user \S+ (\S+) \S+$/) { it[1] }
      sensitive_pattern(/^\s*hash-mgmt-user \S+ password \S+ (\S+)(?: usertype .*)?$/) { it[1] }
      sensitive_pattern(/^\s*hash-mgmt-user \S+ password (\S+)(?: usertype .*)?$/) { it[1] }

      runbook :get do |book|
        book.command('show version') do |result|
          comment(result.output.each_line.grep_v(/^(?:Switch|AP) uptime is |^Reboot Time and Cause/).join)
        end
        book.command('show activate status') do |result|
          comment("#{result.output.each_line.grep_v(/^(?:Activate |Provision interval|Cloud Activation Key)/).join}\n")
        end
        book.command('show aps') do |result|
          comment("#{result.output.each_line.map { aps_line(it) }.join}\n")
        end
        book.command('show running-config no-encrypt')
      end

      communication :telnet do |config|
        config.username_prompt = /^User:\s*/
        config.password_prompt = /^Password:\s*/
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
        end
        config.pre_logout do |run|
          run.cli.write("exit\n") if run.secret('enable') || run.param('enable') == 'true'
          run.cli.write("exit\n")
        end
      end

      class << self
        # Drops the per-radio columns of `show aps`, which change on their own.
        #
        # @param line [String] a line of `show aps`
        # @return [String] the line with the volatile columns removed
        #: (String line) -> String
        def aps_line(line)
          if line.match?(/^Name/)
            line.sub(/^(Name +IP Address +).*(Type +IPv6 Address +).*(Serial #).*$/, '\1\2\3')
          else
            line.sub(/^(\S+ +\S+ +)(?:\S+ +){3}(\S+ +\S+ +)(?:\S+ +){2}(\S+) +.*$/, '\1\2\3')
          end
        end
      end
    end
  end
end

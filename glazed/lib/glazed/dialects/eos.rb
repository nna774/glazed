# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/eos.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # Arista EOS. Ported from oxidized's eos model.
    #
    # Node secrets: "enable" is sent as the enable password; without it, param
    # "enable" set to "true" runs `enable` without one.
    class Eos < Base
      # Optional encoding prefix of a secret (0 plaintext, 5 and sha512 hashes, 7 and 8a reversible).
      SECRET_TYPE = '(?:(?:0|5|7|8a|sha512) )?'

      prompt(/^.+[#>]$/)
      comment_prefix '! '

      sensitive_pattern(/^snmp-server community (?:(?:0|7|8a) (?=\S+ (?:ro|rw)\b))?(\S+)/) { it[1] }
      # SNMPv3 hosts carry a user name, not a community.
      sensitive_pattern(/^snmp-server host (?!.* version 3 )\S+(?> vrf \S+)?(?> informs?| traps)?(?> version (?:1|2c))? +(\S+)/) { it[1] }
      sensitive_pattern(/^snmp-server user .*? auth (?:md5|sha\d*) (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^snmp-server user .*? priv \w+ (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^enable (?:secret|password)(?: level \d+)? #{SECRET_TYPE}(\S+)/) { it[1] }
      sensitive_pattern(/^username \S+ .*?(?:secret|password) #{SECRET_TYPE}(\S+)/) { it[1] }
      sensitive_pattern(/^\s+(?:secret|password) #{SECRET_TYPE}(\S+)/) { it[1] }
      sensitive_pattern(/^(?:tacacs|radius)-server (?:.+ )?key (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^\s+server \S+(?: .+)? key (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^\s*key (?:\h+ )?(?:0|7|8a) (\S+)/) { it[1] }
      sensitive_pattern(/^\s*(?:encryption-key|key-string|pre-shared-key) (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^\s*(?:isis |ip ospf )?authentication(?:-key| key) (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^\s*ip ospf message-digest-key \d+ \S+ (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^\s*neighbor \S+ password (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^\s*vrrp \d+ authentication text (\S+)/) { it[1] }
      sensitive_pattern(/^ntp authentication-key \d+ \S+ (?:(?:0|7|8a) )?(\S+)/) { it[1] }
      sensitive_pattern(/^service unsupported-transceiver \S+ (\S+)/) { it[1] }
      sensitive_pattern(/-(?:cv|ingest)auth=key,(\S+)/) { it[1] }

      runbook :get do |book|
        book.command('show inventory | no-more') { comment(it.output) }
        book.command('show running-config | no-more | exclude ! Time:')
      end

      communication :ssh, :telnet do |config|
        config.post_login do |run|
          if (enable = run.secret('enable'))
            run.cli.write("enable\n")
            run.cli.expect(/[pP]assword:\s?$/)
            run.cli.write("#{enable.value}\n")
            run.cli.expect(run.cli.prompt)
          elsif run.param('enable') == 'true'
            run.cli.command('enable')
          end
          run.cli.command('terminal length 0')
        end
        config.pre_logout { |run| run.cli.write("exit\n") }
      end
    end
  end
end

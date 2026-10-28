# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/edgeos.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # Ubiquiti EdgeOS (EdgeRouter, Vyatta based).
    #
    # Collects `show configuration commands`, the flat `set ...` form, so a diff is one line per change.
    # The login shell is vbash, whose prompt is `user@host:~$`.
    class Edgeos < Base
      prompt(/^([\w.-]+@[\w.-]+:[~\w\/.-]*\$\s?)$/)
      comment_prefix '# '

      filter_output { |output| output.gsub(/[ \t\r]+$/, '') }

      # A value is quoted when it has characters the CLI treats specially.
      VALUE = %q(('[^']*'|\S+)) #: String

      # Credentials in any node of the tree: user passwords, BGP/OSPF/RIP/VRRP authentication, PPPoE, dynamic DNS,
      # IPsec pre-shared keys, RADIUS/TACACS secrets, SNMPv3 keys, WireGuard keys. Public keys (`public-keys NAME key`)
      # are not secrets and stay. The keyword must be a whole word, so `disable-password-authentication` is left alone.
      sensitive_pattern(
        /^set \S.* (?:encrypted-password|plaintext-password|password|pre-shared-secret|md5-key|plaintext-key|encrypted-key|private-key|secret) #{VALUE}\s*$/,
      ) { it[1] }

      # `community NAME` is a secret only under `service snmp`; `match community community-list 100` in a route-map is not.
      sensitive_pattern(/^set service snmp community #{VALUE}/) { it[1] }
      sensitive_pattern(/^set service snmp trap-target \S+ community #{VALUE}/) { it[1] }

      # The connection string carries the UNMS key.
      sensitive_pattern(/^set service unms connection #{VALUE}/) { it[1] }

      # The archive URL can embed credentials (scp://user:password@host/path).
      sensitive_pattern(/^set system config-management commit-archive location #{VALUE}/) { it[1] }

      runbook :get do |book|
        book.command('show version | no-more') { comment(it.output.gsub(/^Uptime:\s.+\n?/, '')) }
        book.command('show configuration commands | no-more')
      end

      communication :telnet do |config|
        config.username_prompt = /login:\s/
        config.password_prompt = /^Password:\s/
      end

      communication :ssh, :telnet do |config|
        config.pre_logout { |run| run.cli.write("exit\n") }
      end
    end
  end
end

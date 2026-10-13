# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/necix.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # NEC UNIVERGE IX series.
    class NecIx < Base
      prompt(/^(\([\w.-]*\)\s[#$]|^\S+[$#]\s?)$/)
      comment_prefix '! '

      interact(/^--More--$/) do |cli, _buffer, match|
        cli.write(' ')
        Actions::Replace.new(content: match.pre_match + match.post_match)
      end

      sensitive_pattern(/^username \S+ password \S+ (\S+)/) { it[1] }
      sensitive_pattern(/^snmp-agent \S+ community (\S+).*/) { it[1] }
      sensitive_pattern(/^ikev2 authentication psk id .+ key \S+ (\S+).*/) { it[1] }
      sensitive_pattern(/^ike policy ike-policy .+ key \S+ (\S+).*/) { it[1] }
      sensitive_pattern(/^radius host .+ key \S+ (\S+).*/) { it[1] }
      sensitive_pattern(/^\s*authentication (?:secret-)?password \S+ (\S+)/) { it[1] }
      sensitive_pattern(/^\s*ngn radius-auth password \S+ (\S+)/) { it[1] }
      sensitive_pattern(/^\s*usbmem authentication .+ password-file \S+ \S+ (\S+)/) { it[1] }
      sensitive_pattern(/^web-auth username \S+ (?:secret-)?password (\S+)/) { it[1] }
      sensitive_pattern(/^\s*area \S+ virtual-link .* authentication-key (\S+)/) { it[1] }
      sensitive_pattern(/^\s*ip ospf authentication-key (\S+)/) { it[1] }
      sensitive_pattern(/^\s*ip ospf message-digest-key (\S+)/) { it[1] }
      sensitive_pattern(/^\s*neighbor \S+ password (\S+)/) { it[1] }
      sensitive_pattern(/^\s*password (?:plain |secret )?(\S+)/) { it[1] }
      sensitive_pattern(/^\s*l2tp password \S+ (\S+)/) { it[1] }
      sensitive_pattern(/^\s*vrrp \S+ authentication (\S+)/) { it[1] }
      sensitive_pattern(/^\s*nm account \S+ password \S+ (\S+)/) { it[1] }
      sensitive_pattern(/^snmpv3 user \S+ .+ priv \S+ (?:plain|secret) (\S+)/) { it[1] }
      sensitive_pattern(/^snmpv3 user \S+ .+? (?:plain|secret) (\S+)/) { it[1] }
      sensitive_pattern(/^http-server cross-site (?:secret-)?password (\S+)/) { it[1] }
      sensitive_pattern(/^http-server (?:guest-|monitor-)?username \S+ (?:secret-)?password (\S+)/) { it[1] }
      sensitive_pattern(/^startup (?:config-download|software-update) .+ (?:secret-)?password (\S+)/) { it[1] }

      runbook :get do |book|
        book.command('show running-config') do |result|
          result.output.each_line.grep_v(/^!.*Current time.*$/).join
        end
      end

      communication :telnet do |config|
        config.username_prompt = /^Username:\s/i
        config.password_prompt = /^Password:\s/i
      end

      communication :ssh, :telnet do |config|
        config.post_login do |run|
          raise Glazed::Error, 'CONFIG process is occupied' if run.cli.command('configure').output.match?(/CONFIG process is occupied/)

          run.cli.command('terminal length 0')
        end
        config.pre_logout do |run|
          run.cli.write("\cZ")
          run.cli.write("exit\n")
        end
      end
    end
  end
end

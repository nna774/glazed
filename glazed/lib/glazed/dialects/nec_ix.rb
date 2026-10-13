# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/base'

module Glazed
  module Dialects
    class NecIx
      include Glazed::Dialects::Base

      prompt(/^(\([\w.-]*\)\s[#$]|^\S+[$#]\s?)$/)

      interact(/^--More--$/) do |cli, buf, match|
        cli.send(' ')
        Glazed::Dialects::Base::Actions::Replace.new(content: buf.sub(match[0], ''))
      end

      sensitive_pattern(/^username \S+ password \S+ (\S+)/) { _1[1] }
      sensitive_pattern(/^snmp-agent \S+ community (\S+).*/) { _1[1] }
      sensitive_pattern(/^ikev2 authentication psk id .+ key \S+ (\S+).*/) { _1[1] }
      sensitive_pattern(/^ike policy ike-policy .+ key \S+ (\S+).*/) { _1[1] }
      sensitive_pattern(/^radius host .+ key \S+ (\S+).*/) { _1[1] }
      sensitive_pattern(/^\s*authentication (?:secret-)?password \S+ (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*ngn radius-auth password \S+ (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*usbmem authentication .+ password-file \S+ \S+ (\S+)/) { _1[1] }
      sensitive_pattern(/^web-auth username \S+ (?:secret-)?password (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*area \S+ virtual-link .* authentication-key (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*ip ospf authentication-key (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*ip ospf message-digest-key (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*neighbor \S+ password (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*password (?:plain |secret )?(\S+)/) { _1[1] }
      sensitive_pattern(/^\s*l2tp password \S+ (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*vrrp \S+ authentication (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*nm account \S+ password \S+ (\S+)/) { _1[1] }
      sensitive_pattern(/^snmpv3 user \S+ .+ priv \S+ (?:plain|secret) (\S+)/) { _1[1] }
      sensitive_pattern(/^snmpv3 user \S+ .+? (?:plain|secret) (\S+)/) { _1[1] }
      sensitive_pattern(/^http-server cross-site (?:secret-)?password (\S+)/) { _1[1] }
      sensitive_pattern(/^http-server (?:guest-|monitor-)?username \S+ (?:secret-)?password (\S+)/) { _1[1] }
      sensitive_pattern(/^startup (?:config-download|software-update) .+ (?:secret-)?password (\S+)/) { _1[1] }

      runbook :get do |book|
        book.command('show running-config') do |result|
          result.output.each_line
            .grep_v(/^!.*Current time.*$/)
            .to_a
            .join
        end
      end

      communication :telnet do |config|
        config.username_prompt = /^Username:\s/i
        config.password_prompt = /^Password:\s/i
      end
      communication :ssh, :telnet do |config|
        config.post_login do |cli|
          result = cli.cmd("configure")
          if result.output.match?(/CONFIG process is occupied/)
            raise "CONFIG process is occupied"
          end
          cli.cmd("terminal length 0")
        end
        config.pre_logout do |cli|
          cli.send("\cZ")
          cli.send("exit\n")
        end
      end
    end
  end
end

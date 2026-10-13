# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # Allied Telesis AlliedWare Plus.
    class Awplus < Base
      prompt(/^(\r?[\w.@:\/-]+[#>]\s?)$/)
      comment_prefix '! '

      interact(/--More--/) do |cli, _buffer, match|
        cli.write(' ')
        Actions::Replace.new(content: match.pre_match + match.post_match)
      end

      filter_data { |fragment| fragment.gsub("\e[7m\e[m", '').delete("\r") }

      sensitive_pattern(/^snmp-server community\s+(.+)$/) { it[1] }
      sensitive_pattern(/^snmp-server user .+auth \S+ (\S+)$/) { it[1] }
      sensitive_pattern(/^snmp-server user .+priv \S+ (\S+)$/) { it[1] }
      sensitive_pattern(/^username .+? privilege \d+\s+(\S+).*/) { it[1] }
      sensitive_pattern(/^username .+? password \d+\s+(\S+).*/) { it[1] }
      sensitive_pattern(/^username .+? secret \d+\s+(\S+).*/) { it[1] }
      sensitive_pattern(/^enable (?:password|secret) (?:\d )?\s*(\S+)/) { it[1] }
      sensitive_pattern(/\s+(?:password|secret) (?:\d )?(\S+)/) { it[1] }
      sensitive_pattern(/^tacacs-server key (?:\d )?(\S+)/) { it[1] }
      sensitive_pattern(/^radius-server key (\S+)/) { it[1] }
      sensitive_pattern(/^auth-mac (?:encrypted )?password (\S+)/) { it[1] }
      sensitive_pattern(/^\s*ppp password (?:encrypted )?(.+)$/) { it[1] }
      sensitive_pattern(/^\s*key-string (?:encrypted )?(.+)$/) { it[1] }
      sensitive_pattern(/^\s+password (?:encrypted )?(.+)$/) { it[1] }
      sensitive_pattern(/^\s+key (?:encrypted )?(.+)$/) { it[1] }
      sensitive_pattern(/^\s+neighbor \S+ password (.+?)(?: encrypted)?$/) { it[1] }
      sensitive_pattern(/^\s+ip ospf \S+ message-digest-key \d+ md5 (?:encrypted )?(.+)$/) { it[1] }
      sensitive_pattern(/^\s+ip ospf \S+ authentication-key (?:encrypted )?(.+)$/) { it[1] }
      sensitive_pattern(/^\s*aes-key (?:encrypted )?(.+)$/) { it[1] }

      runbook :get do |book|
        book.command('show system') do |result|
          stable = result.output.each_line.grep_v(
            /\A\s*\n\z
            |System\ Status
            |RAM\s*:
            |Uptime\s*:
            |Flash\s*:
            |Current\ software\s*:
            |Software\ version\s*:
            |Build\ date\s*:
            /x,
          )
          comment("-- show system #{'-' * 66}\n#{stable.join}#{'-' * 80}\n")
        end
        book.command('show running-config')
      end

      communication :telnet do |config|
        config.username_prompt = /^login:\s/i
        config.password_prompt = /^password:\s/i
      end

      communication :ssh, :telnet do |config|
        config.post_login do |run|
          if (enable = run.secret('enable'))
            run.cli.write("enable\n")
            run.cli.expect(/^Password:\s/)
            run.cli.write("#{enable.value}\n")
            run.cli.expect(run.cli.prompt)
          else
            run.cli.command('enable')
          end
        end
        config.pre_logout { |run| run.cli.write("exit\n") }
      end
    end
  end
end

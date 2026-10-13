# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/base'

module Glazed
  module Dialects
    class Awplus
      include Glazed::Dialects::Base

      prompt(/^(\r?[\w.@:\/-]+[#>]\s?)$/)

      interact(/--More--/) do |cli, buf, match|
        cli.send(' ')
        Glazed::Dialects::Base::Actions::Replace.new(content: buf.sub(match[0], ''))
      end

      filter_data do |fragment|
        fragment.gsub!("\e[7m\e[m", '')
        fragment.delete!("\r")
        fragment
        # TODO:fragment.cut_both
      end

      sensitive_pattern(/^snmp-server community\s+(.+)$/) { _1[1] }
      sensitive_pattern(/^snmp-server user .+auth \S+ (\S+)$/) { _1[1] }
      sensitive_pattern(/^snmp-server user .+priv \S+ (\S+)$/) { _1[1] }
      sensitive_pattern(/^username .+? privilege \d+\s+(\S+).*/) { _1[1] }
      sensitive_pattern(/^username .+? password \d+\s+(\S+).*/) { _1[1] }
      sensitive_pattern(/^username .+? secret \d+\s+(\S+).*/) { _1[1] }
      sensitive_pattern(/^enable (?:password|secret) (?:\d )?\s*(\S+)/) { _1[1] }
      sensitive_pattern(/\s+(?:password|secret) (?:\d )?(\S+)/) { _1[1] }
      sensitive_pattern(/^tacacs-server key (?:\d )?(\S+)/) { _1[1] }
      sensitive_pattern(/^radius-server key (\S+)/) { _1[1] }
      sensitive_pattern(/^auth-mac (?:encrypted )?password (\S+)/) { _1[1] }
      sensitive_pattern(/^\s*ppp password (?:encrypted )?(.+)$/) { _1[1] }
      sensitive_pattern(/^\s*key-string (?:encrypted )?(.+)$/) { _1[1] }
      sensitive_pattern(/^\s+password (?:encrypted )?(.+)$/) { _1[1] }
      sensitive_pattern(/^\s+key (?:encrypted )?(.+)$/) { _1[1] }
      sensitive_pattern(/^\s+neighbor \S+ password (.+?)(?: encrypted)?$/) { _1[1] }
      sensitive_pattern(/^\s+ip ospf \S+ message-digest-key \d+ md5 (?:encrypted )?(.+)$/) { _1[1] }
      sensitive_pattern(/^\s+ip ospf \S+ authentication-key (?:encrypted )?(.+)$/) { _1[1] }
      sensitive_pattern(/^\s*aes-key (?:encrypted )?(.+)$/) { _1[1] }

      runbook :get do |book|
        book.command('show system') do |result|
          out = result.output.each_line
            .grep_v(
              /^$\n
              |System Status\s*.*
              |RAM\s*:.*
              |Uptime\s*:.*
              |Flash\s*:.*
              |Current software\s*:.*
              |Software version\s*:.*
              |Build date\s*:.*
              /x,
            )
            .map { |line| "! #{line}" }
            .to_a
            .join
          Glazed::Dialects::Base::Actions::Multi.new(
            Actions::Append.new(content: "! -- show system ------------------------------------------------------------------"),
            Actions::Append.new(content: out),
            Actions::Append.new(content: "! ---------------------------------------------------------------------------------"),
          )
        end
        book.command('show running-config') { _1.output }
      end

      communication :telnet do |config|
        config.username_prompt = /^login:\s/i
        config.password_prompt = /^password:\s/i
      end
      communication :ssh, :telnet do |config|
        config.post_login do |cli|
          if node.params[:enable]
            cli.send("enable\n")
            cli.expect(/^Password:\s/)
            cli.cmd("#{node.params[:enable]}\r\n") # send and wait for prompt
          else
            cli.cmd("enable")
          end
        end
        config.pre_logout do |cli|
          cli.send("exit\r\n")
        end
      end
    end
  end
end

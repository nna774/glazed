# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/junos.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # Juniper Junos OS.
    #
    # Node params: "junos_license_usage" set to "false" omits the license usage
    # table, whose counts change without configuration changes.
    class Junos < Base
      prompt(/^(\r?[\w.@:\/-]+[#>]\s?)$/)
      comment_prefix '# '

      filter_output { |output| output.gsub(/[ \t\r]+$/, '') }
      # Counters that change without configuration changes.
      filter_output do |output|
        output
          .gsub(/  scale-subscriber (\s+)(\d+)/, '  scale-subscriber                <count>')
          .gsub(/VMX-BANDWIDTH\s+(\d+) (.*)/, 'VMX-BANDWIDTH                  <count> \2')
      end

      sensitive_pattern(/ community (.+) \{$/) { it[1] }
      sensitive_pattern(/"(.+)".*; ## SECRET-DATA$/) { it[1] }

      runbook :get do |book|
        book.raw('show version') do |run|
          output = run.command('show version').output
          run.vars[:model] = output[/^Model: (\S+)/, 1]
          run.emit(comment(output))
        end
        book.command('show chassis hardware') { comment(it.output) }
        book.raw('show system license') do |run|
          output = run.command('show system license').output
          output = output.sub(/^License usage:.*?\n[ \t]*\n/m, '') if run.param('junos_license_usage') == 'false'
          run.emit(
            comment(
              output
                .gsub(/  fib-scale\s+(\d+)/, '  fib-scale                       <count>')
                .gsub(/  rib-scale\s+(\d+)/, '  rib-scale                       <count>'),
            ),
          )
        end
        book.command('show system license keys') { comment(it.output) }
        book.command('show configuration | display omit')
        book.raw('model-specific status') do |run|
          case run.vars[:model]
          when 'mx960'
            run.emit(comment(run.command('show chassis fabric reachability').output))
          when /^(ex22|ex3[34]|ex4|ex8|qfx)/
            run.emit(comment(run.command('show virtual-chassis').output))
          end
        end
      end

      communication :telnet do |config|
        config.username_prompt = /^login:/i
        config.password_prompt = /^password:/i
        config.post_login do |run|
          run.cli.command('set cli screen-length 0')
          run.cli.command('set cli screen-width 0')
        end
        config.pre_logout { |run| run.cli.write("exit\n") }
      end

      communication :ssh do |config|
        config.exec = true
      end
    end
  end
end

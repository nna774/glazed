# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/base'

module Glazed
  module Dialects
    class Junos
      include Glazed::Dialects::Base

      prompt(/^(\r?[\w.@:\/-]+[#>]\s?)$/)

      filter_data do |fragment|
        "#{fragment.each_line.map(&:rstrip).join("\n")}\n"
      end

      sensitive_pattern(/ community (.+) {$/) { _1[1] }
      sensitive_pattern(/"(.+)".*; ## SECRET-DATA$/) { _1[1] }

      runbook :get do |book|
        book.raw do |cli|
          version = cli.command('show version')
          @model = version.output.match(/^Model: (\S+)/)&.[](1)
        end

        book.command('show chassis hardware') { _1.output.each_line.map { |l| "# #{l}" }.join }
        book.command('show system license') do |result|
          result.output
            .gsub(/  fib-scale\s+(\d+)/, '  fib-scale                       <count>')
            .gsub(/  rib-scale\s+(\d+)/, '  rib-scale                       <count>')
            .each_line.map { |l| "# #{l}" }.join
        end
        book.command('show system license keys') { _1.output.each_line.map { |l| "# #{l}" }.join }

        book.command('show configuration | display omit') { _1.output }

        book.raw do |cli, &action|
          case @model
          when 'mx960'
            action.call Actions::Append.new(content: cli.command('show chassis fabric reachability').output.each_line.map { |l| "# #{l}" }.join)
          when /^(ex22|ex3[34]|ex4|ex8|qfx)/
            action.call Actions::Append.new(content: cli.command('show virtual-chassis').output.each_line.map { |l| "# #{l}" }.join)
          end
        end
      end

      communication :telnet do |config|
        config.username_prompt = /^login:/i
        config.password_prompt = /^password:/i

        config.post_login do |cli|
          cli.send("set cli screen-length 0\r\n")
          cli.send("set cli screen-width 0\r\n")
        end
        config.pre_logout do |cli|
          cli.send("exit\r\n")
        end
      end

      communication :ssh do |config|
        config.exec = true
      end
    end
  end
end

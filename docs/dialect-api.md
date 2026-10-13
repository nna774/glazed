# Dialect API

equivalent to Oxidized's _model_.

```ruby
require 'glazed/dialects/base'
module Glazed
  module Dialects
    class Rootware
      include Glazed::Dialects::Base

      # In interactive session, _prompt_ pattern iused to detect the end of the command output.
      prompt /^\r?[a-z0-9]+[#>]\s*$/

      # hook every arrived data to interact with remote CLI (in interactive session)
      interact /--More--/ do |cli, buf, match|
        cli.send(' ')
        case something
        when 1
          Glazed::Dialects::Base::Actions::Replace.new(content: buf)
        when 2
          nil # do nothing
        end
      end

      # Remove noise from received data such as ANSI sequences
      # (equivalent to Oxidized's `cmd :all`)
      filter_data do |fragment|
        fragment.gsub!("\e[7m\e[m", '')
      end

      # Register sensitive patterns. Matched and returned string will be recognised as sensitive string.
      sensitive_pattern(/^enable (?:password|secret) \d (\S+)/i) { |match| match[1] }

      # Whole instruction for :get operation, which is to retrieve a running configuration.
      runbook :get do |book|
        book.command 'show system' do |result|
          cfg = result.output.each_line.grep_v(/Current time:/).map { |line| "! #{line}" }.join
          Glazed::Dialects::Base::Actions::Multi.new(
            Actions::Append.new(content: "! show system -------"),
            Actions::Append.new(content: cfg),
            Actions::Append.new(content: "! !!!!!!!!!!!!!!!!!!!"),
          )
        end
        book.command 'show running-config' do |result|
          result.output # default to append
        end

        # advanced, do something interactive thing
        book.raw do |cli, &action|
          cli.send("foobarbaz")
          action.call Glazed::Dialects::Base::Actions::Multi.new([
            # ...,
          ])
          cli.expect("something")
        end
      end

      # Per communicator configuration
      communication :telnet do |config|
        config.username_prompt = /login:\s/
        config.password_prompt = /password:\s/
      end
      communication :ssh, :telnet do |config|
        config.post_login do |cli|
          if config.node.params[:enable]
            cli.send("enable\n")
            cli.expect(/^Password:\s/)
            cli.cmd("#{config.node.params[:enable]}\r\n") # send and wait for prompt
          else
            cli.cmd("enable\n")
          end
        end
      end
    end
  end
end
```

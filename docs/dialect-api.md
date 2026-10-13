# Dialect API

A dialect is the equivalent of an oxidized _model_: it describes how to talk to one kind of device and how to collect its configuration. Dialects are classes under `Glazed::Dialects`, found by snake_case name (`Glazed::Dialects.find('nec_ix')` resolves `Glazed::Dialects::NecIx`, requiring `glazed/dialects/nec_ix` on demand, so other gems can ship dialects).

Declarations are inherited. A subclass adds to its parent's filters, interactions, sensitive patterns and communication blocks, and replaces its prompt, comment prefix and runbooks.

```ruby
require 'glazed/dialects/base'

module Glazed
  module Dialects
    class Rootware < Base
      # Prompt pattern, matched against the session buffer to find the end of command output.
      prompt(/^\r?[a-z0-9]+[#>]\s*$/)

      # Prefix used by `comment(text)`.
      comment_prefix '! '

      # Respond to patterns in the session buffer, such as a pager prompt. The returned action
      # (Actions::Append, Actions::Replace, Actions::Multi, a String to append, or nil) edits
      # the buffer, and must remove the pattern or the interaction fires again.
      interact(/--More--/) do |cli, _buffer, match|
        cli.write(' ')
        Actions::Replace.new(content: match.pre_match + match.post_match)
      end

      # Filter each received fragment, such as removing ANSI sequences.
      # Fragments split at arbitrary points, so only per-character edits are safe here.
      filter_data { |fragment| fragment.gsub("\e[7m\e[m", '').delete("\r") }

      # Filter the whole output of every runbook command (oxidized's `cmd :all`).
      filter_output { |output| output.gsub(/[ \t]+$/, '') }

      # Locate secrets in the collected configuration. The pattern is matched against the
      # whole text, so multiline patterns work; the block returns the secret within the match.
      sensitive_pattern(/^enable (?:password|secret) \d (\S+)/) { it[1] }

      # Steps of the :get operation, which collects the running configuration.
      runbook :get do |book|
        # The block's return value is emitted: a String is appended, nil emits nothing.
        book.command('show system') do |result|
          comment(result.output.each_line.grep_v(/Current time:/).join)
        end
        # Without a block, the output is appended as is.
        book.command('show running-config')

        # Drive the run directly. `run.vars` is scratch space shared by the steps of one run.
        book.raw('model-specific') do |run|
          model = run.command('show model').output.strip
          run.emit(comment(run.command('show stack').output)) if model.start_with?('stack')
        end
      end

      # Per-transport settings. Blocks for the transport apply in declaration order, parent first.
      communication :telnet do |config|
        config.username_prompt = /login:\s/
        config.password_prompt = /password:\s/
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
```

## Communication settings

- `exec`: run each command on its own exec channel when the transport supports it (SSH), instead of the interactive shell.
- `username_prompt`, `password_prompt`: when set, the session logs in by answering these prompts. This applies to SSH too, for devices that ask for credentials inside the session after SSH authentication.
- `post_login`, `pre_logout`: hooks around the runbook. They receive the same `run` as runbook steps.

## Encoding

Collected configuration must be valid UTF-8: a command whose output is not fails the node with `Glazed::InvalidEncoding`. Output reaches `filter_output` as bytes, so a dialect for a device using another encoding converts it there:

```ruby
filter_output { |output| output.dup.force_encoding(Encoding::Shift_JIS).encode(Encoding::UTF_8) }
```

## Runs

Runbook steps and hooks receive a `Glazed::Dialect::Run`:

- `run.cli`: the `Glazed::CliSession` (`write`, `expect`, `command`, `prompt`).
- `run.command(line)`: `cli.command` with the dialect's output filters applied.
- `run.emit(action)`: edit the collected configuration.
- `run.node`, `run.param(name)`, `run.secret(name)`: the node being run against, its `params` and its `secrets` from the inventory.
- `run.vars`: scratch space for the run.

Blocks are evaluated with the dialect class as `self`, so `comment(text)` is available inside them.

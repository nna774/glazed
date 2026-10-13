# Oxidized model shim

The `glazed-oxidized` gem runs [Oxidized](https://github.com/ytti/oxidized) model files as glazed dialects. A node whose dialect is `oxidized_<model>` runs the model file `<model>.rb`: `oxidized_eos` runs `eos.rb`, `oxidized_panos` runs `panos.rb`.

Use it for devices that glazed has no native dialect for. Native dialects remain preferable where they exist, since their sensitive patterns are written for glazed rather than derived from a model (see [Secrets](#secrets)).

## Requirements

- Ruby 4.0 or later, started with `RUBY_BOX=1` in the environment. Without it, using an `oxidized_*` dialect fails with `Glazed::Oxidized::UnavailableError`.
- Oxidized model files: the `oxidized` gem, or a directory of models. glazed-oxidized does not depend on the oxidized gem; it only reads its model files.

## Usage

Require the gem from the glazed config so it registers the `oxidized_*` dialects, and name the model in the inventory:

```jsonc
// glazed.json
{
  "requires": ["glazed/oxidized"],
  "inventory": [{"json_files": {"paths": ["inventory/*.json"]}}],
  // storages and workflows as usual
}
```

```jsonc
// inventory/edge.json
{
  "defaults": {"group": "edge", "username": "backup", "password": {"env": "BACKUP_PASSWORD"}},
  "nodes": [
    {"name": "sw1", "dialect": "oxidized_eos", "params": {"enable": "true"}},
    {"name": "fw1", "dialect": "oxidized_fortios", "transport": "telnet", "secrets": {"enable": {"env": "FW_ENABLE"}}}
  ]
}
```

```
RUBY_BOX=1 bundle exec glazed run -c glazed.json
```

### Finding models

Model files are searched in the order Oxidized uses:

1. `$OXIDIZED_HOME/model`, or `~/.config/oxidized/model` when `OXIDIZED_HOME` is unset. Your own and overridden models go here, as with Oxidized.
2. `lib/oxidized/model` of the installed `oxidized` gem, when Rubygems or Bundler can see one.

To search elsewhere, set the list from Ruby, for example in a file listed in the config's `requires`:

```ruby
require 'glazed/oxidized'
Glazed::Oxidized.model_paths = ['/etc/glazed/oxidized-models', *Glazed::Oxidized.model_paths]
```

As in Oxidized, the file must define a class whose name matches the file name ignoring case (`eos.rb` defines `EOS`). A file that defines none fails with `Glazed::Oxidized::ModelNotFound`; a name with no file is reported like any unknown dialect.

## Node variables

Oxidized models read per-node settings with `vars(name)`. On glazed, `vars` reads:

1. the node's `params`, with `"true"` and `"false"` turned into booleans, because Oxidized models commonly test `vars(:enable) == true`;
2. then the node's `secrets`, resolved on first use.

Oxidized's own variables keep their meaning where they apply:

| Variable | Effect |
|---|---|
| `remove_secret` | runs the model's `cmd :secret` blocks (see [Secrets](#secrets)) |
| `ssh_no_exec` | disables `exec true` in `cfg :ssh` blocks; read only after login, see [Limitations](#limitations) |
| `enable`, and any model-specific variable | passed to the model as is |

Variables controlling Oxidized's SSH client, such as `ssh_port`, `ssh_keys` or `auth_methods`, have no effect: glazed's transports take their settings from the node (`port`, `username`, `password`, `transport_options`).

`@node` inside a model provides `name`, `ip` (the node's `host`, or its name when empty), `group`, `auth` (`{username:, password:}`), `prompt` and `vars`.

## How a model maps to glazed

| Oxidized | glazed |
|---|---|
| `prompt` | the dialect prompt; Oxidized's default `/^([\w.@-]+[#>]\s?)$/` when the model declares none |
| `comment` | the comment prefix |
| `expect` | an interaction; its block's return value replaces the session buffer |
| `cfg :ssh`, `cfg :telnet` | communication settings for the `ssh` and `telnet` transports |
| `username`, `password` in `cfg` | `username_prompt`, `password_prompt` |
| `exec true` in `cfg :ssh` | `exec`: each command runs on its own SSH exec channel |
| `post_login`, `pre_logout` in `cfg` | `post_login`, `pre_logout` hooks |
| `cmd`, `pre`, `post` | one step of the `:get` runbook, running the model's `get` |
| `cmd :all` | applied to each command output, as in Oxidized |
| `cmd :secret` | sensitive patterns; applied to each command output with `remove_secret` |

On a shell, `cmd` returns output the way Oxidized inputs do: with the echoed command line and the trailing prompt. Models remove them themselves, usually with `cut_both` in `cmd :all`. On an exec channel the output has neither.

Commands from `cmd` are written with `\n`. The Telnet input's `cmd(line, nil)`, which sends without waiting, writes `\r\n` as Oxidized's does.

## Secrets

glazed keeps a raw copy of each configuration and publishes a redacted one, using the sensitive patterns each dialect declares. A dialect built from a model declares one sensitive pattern per substitution in the model's `cmd :secret` blocks, so the `redact` step works as with native dialects, including `MODE_HMAC`.

When the dialect is built, each `cmd :secret` block runs once on a stand-in for command output that records its `sub` and `gsub` calls. Each recorded pattern becomes a sensitive pattern. The secret in a match is what the replacement drops: the match without the start and end it shares with the expanded replacement, never splitting a word. For example, EdgeOS's `gsub!(/password (\S+).*/, 'password <secret removed>')` redacts everything after `password `, as Oxidized removes it.

- All patterns run on the whole configuration at once, where Oxidized applies them one after another to each command output. Redaction therefore hides at least what Oxidized removes, but misses a secret in output the model turns into comments, as the comment prefix stops patterns anchored with `^` from matching.
- A model whose `cmd :secret` blocks do anything but call `sub` or `gsub` with a pattern and a string can still collect, but its `redact` step fails with `Glazed::Oxidized::UnredactableModel` rather than publish secrets. All of Oxidized's own models record.
- A model without `cmd :secret` blocks declares no sensitive patterns, and the `redact` step publishes its configuration unchanged.

Patterns the model lacks can be added to its dialect from Ruby, for example in a file listed in the config's `requires`:

```ruby
require 'glazed/oxidized'
Glazed::Dialects.find('oxidized_edgeos').sensitive_pattern(/^set service snmp community (\S+)/) { it[1] }
```

The node param `remove_secret` set to `"true"` also runs the model's `cmd :secret` blocks while collecting, as with Oxidized's `remove_secret` variable, so the raw copy lacks the secrets as well.

## Isolation

Oxidized models are plain Ruby files evaluated at the top level. Many define helper methods on `Object`, patch core classes, set globals, or `require` libraries of their own. Loaded into glazed's process, they could change how glazed itself behaves.

Each model file is therefore loaded into its own [Ruby::Box](https://docs.ruby-lang.org/en/4.0/Ruby/Box.html), together with the emulated Oxidized API. Inside the box the model sees `Oxidized::Model`, `Refinements`, `Oxidized::SSH` and so on; outside it none of them exist. Class definitions, constants, monkey patches and global variable values stay within the box, and two models defining the same helper do not conflict. A model file that `require_relative`s another model (`iosxe.rb` loads `ios.rb`) loads it into the same box.

Each model is loaded once per process, when a node first uses it, and its dialect is kept as `Glazed::Dialects::Oxidized<Model>`.

```
main box                                    model box (one per model file)
────────────────────────────────────────    ──────────────────────────────────
Collector ─► ModelDialect ─► CliSession     prelude: Oxidized::Model, Input,
                 │              ▲            SSH, Telnet, Refinements
                 │              │
                 └──► Bridge ◄──┴──────────  model instance, input instance
                      (per session)          (call bridge.cmd / write / expect)
```

- `Glazed::Oxidized::ModelBox` creates the box, loads the prelude and the model file, and finds the model class.
- `Glazed::Oxidized::ModelDialect` builds the dialect class from the model's declarations.
- `Glazed::Oxidized::Bridge` belongs to one CLI session. It holds the model instance and the input instance, and carries their `cmd`, `send` and `expect` calls to the session.
- `Glazed::Oxidized::NodeView` presents the glazed node as `@node` and `vars`.

Objects cross between boxes freely; only definitions are separate. The box-side classes call into the bridge, and the bridge calls methods on the model instance.

## Limitations

- **Transports:** only the SSH and Telnet inputs are emulated. Models collecting over HTTP, SCP, FTP or TFTP fail. A node on a transport the model has no `cfg` block for fails with `Glazed::Oxidized::UnsupportedTransport`.
- **Vars in `cfg` blocks:** glazed decides login prompts and `exec` before connecting, so the `cfg` blocks are evaluated without the node. `vars` returns nil there, and settings that depend on it, such as `ssh_no_exec`, have no effect. Commands and blocks inside `post_login` and `pre_logout` run later and see the node's vars.
- **Login:** glazed answers the user name prompt, then the password prompt, then waits for the prompt, in that order. Oxidized accepts them in any order.
- **Unavailable API:** `Oxidized.config`, output types (`cfg.type`) and per-node prompt overrides. `Oxidized.logger` writes warnings and errors to standard error and drops debug and info messages.
- **Output formatting** follows the model, not glazed. For example, Oxidized's `comment` keeps the space after the prefix on empty lines, where glazed's dialects strip it.
- **Timing:** commands run with Oxidized's semantics, including its races. A model that `send`s a command and then runs `cmd` without waiting for the prompt can match the first command's prompt, as it can on Oxidized.

## Development

The specs need Ruby 4.0 and Ruby::Box:

```
cd glazed-oxidized
RUBY_BOX=1 bundle exec rspec
```

They replay the device simulations of the glazed gem's own specs through models under `glazed-oxidized/spec/fixtures/model`, and through Oxidized's `aireos.rb` and `junos.rb` kept unmodified in `third_party/oxidized`.

With `OXIDIZED_SOURCE` set to an Oxidized source tree, they also replay Oxidized's own model tests (`spec/model/data`) for selected models with that tree's model files, and check that redaction hides what `remove_secret` removes. CI runs them against Oxidized 0.32.2.

```
RUBY_BOX=1 OXIDIZED_SOURCE=~/src/oxidized bundle exec rspec
```

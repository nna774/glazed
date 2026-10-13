# glazed: Modern network device configuration backup

glazed collects configuration from network devices over SSH or Telnet, keeps the raw copy where only operators can read it, and publishes a redacted copy to git for the wider team. It is a successor of [Oxidized](https://github.com/ytti/oxidized), built as small building blocks that run from a command, and are designed to run as separate steps under an orchestrator such as AWS Step Functions.

If you need a web UI or a REST API, Oxidized is the better choice for now. Oxidized's device models can run on glazed through `glazed-oxidized`. See [Difference with Oxidized](#difference-with-oxidized).

## Features

- **Secret aware.** Raw configuration and redacted configuration go to separate storages. Secrets located by each dialect are removed, or replaced with a keyed HMAC so a rotated secret still shows up in diffs without being revealed.
- **Git flow.** Redacted configuration is committed continuously to a topic branch of a team repository, so engineers can open a pull request once a change is complete and explain what changed and why. See [docs/workflow-with-pull-request.md](docs/workflow-with-pull-request.md).
- **Cloud storage.** Raw configuration can be kept in a versioned S3 bucket (`glazed-aws`), and redacted configuration pushed to GitHub through its API without a local clone.
- **No empty updates.** Storages write only content that differs from what they hold: no empty commits, no new S3 object versions for unchanged devices.
- **Building blocks.** Collecting, redacting and storing are separate components with protobuf inputs and outputs, usable on their own or as steps of a workflow.
- **Dialect API.** Devices are described by a class-based DSL with inheritance, in the spirit of Oxidized models, where per-run state lives outside the dialect. See [docs/dialect-api.md](docs/dialect-api.md).

## Supported devices

| Dialect | Devices | Transports |
|---|---|---|
| `ios` | Cisco IOS, IOS XE | SSH, Telnet |
| `wlc` | Cisco Wireless LAN Controller (AireOS) | SSH, Telnet |
| `junos` | Juniper Junos OS | SSH (exec channel), Telnet |
| `nec_ix` | NEC UNIVERGE IX | SSH, Telnet |
| `awplus` | Allied Telesis AlliedWare Plus | SSH, Telnet |

All five are ported from Oxidized models. Other gems can add dialects as `Glazed::Dialects::<Name>` in `glazed/dialects/<name>.rb`, or resolve names with `Glazed::Dialects.add_resolver`.

Any other Oxidized model runs through `glazed-oxidized` as the `oxidized_<model>` dialect, such as `oxidized_eos`. See [docs/oxidized-shim.md](docs/oxidized-shim.md).

## Requirements

- Ruby 3.4 or later
- `git`, for the `git` storage
- The `glazed-aws` gem, for the `s3` storage
- Ruby 4.0 or later and the `glazed-oxidized` gem, for Oxidized models

## Installation

glazed is not released on RubyGems yet. Install it from this repository with Bundler:

```ruby
# Gemfile
source 'https://rubygems.org'

gem 'glazed', git: 'https://github.com/sorah/glazed', glob: 'glazed/*.gemspec'
gem 'glazed-aws', git: 'https://github.com/sorah/glazed', glob: 'glazed-aws/*.gemspec' # for S3
gem 'glazed-oxidized', git: 'https://github.com/sorah/glazed', glob: 'glazed-oxidized/*.gemspec' # for Oxidized models
```

```
bundle install
bundle exec glazed run --help
```

## Quick start

### 1. Describe devices

Inventory files are ProtoJSON of `glazed.v1.InventoryFile`. `defaults` fill fields each node leaves unset.

```jsonc
// inventory/core.json
{
  "defaults": {"group": "core", "dialect": "ios", "username": "backup", "password": {"env": "BACKUP_PASSWORD"}},
  "nodes": [
    {"name": "rt1", "host": "192.0.2.1", "secrets": {"enable": {"env": "ENABLE_SECRET"}}},
    {"name": "sw1", "host": "192.0.2.2", "dialect": "junos"}
  ]
}
```

### 2. Write a workflow

This config keeps raw configuration in a local git repository, and publishes a redacted copy to another one that is pushed to a remote:

```jsonc
// glazed.json
{
  "inventory": [{"json_files": {"paths": ["inventory/*.json"]}}],
  "storages": {
    "raw": {"git": {"path": "/var/lib/glazed/raw"}},
    "redacted": {"git": {"path": "/var/lib/glazed/redacted", "remote": "git@example.com:netops/configs.git"}}
  },
  "workflows": {
    "backup": {"steps": [
      {"name": "fetch", "fetch": {"output": "raw", "storage": "raw"}},
      {"name": "redact", "redact": {"input": "raw", "output": "redacted", "storage": "redacted",
                                    "redaction": {"mode": "MODE_HMAC", "hmac_key": {"env": "GLAZED_HMAC_KEY"}}}}
    ]}
  }
}
```

The comments are for this README only: ProtoJSON files must not contain them.

### 3. Run it

```
BACKUP_PASSWORD=... ENABLE_SECRET=... GLAZED_HMAC_KEY=... bundle exec glazed run -c glazed.json
```

Each node and step logs one JSON line on stderr, and the run ends with a summary such as `completed 2 of 2 nodes, 1 changed, 0 failed`. Run it from cron or a systemd timer to keep the copies current, or keep it running with `glazed orchestrate` ([docs/orchestrator.md](docs/orchestrator.md)), which runs workflows for each node on an interval and soon after a signal such as `glazed signal sw1`. The same workflows can run on AWS Step Functions with `glazed-aws` ([docs/aws-step-functions.md](docs/aws-step-functions.md)).

## Usage

```
glazed run -c CONFIG [-w WORKFLOW] [--only NAME,...] [-j N]
glazed orchestrate -c CONFIG [-j N]
glazed signal -c CONFIG [-w WORKFLOW,...] [--source SOURCE] [--now] (NAME... | --all)
glazed status -c CONFIG [-w WORKFLOW,...] [--only NAME,...] [--failing] [--json]
glazed version
```

- `-c, --config PATH`: config file, ProtoJSON of `glazed.v1.Config`; the `GLAZED_CONFIG_FILE` environment variable when omitted
- `-w, --workflow NAME`: workflow to run; optional when the config defines only one
- `--only NAME,...`: run only for these nodes, comma-separated
- `-j, --jobs N`: nodes processed in parallel (default: `jobs` in the config, or 4)

`glazed orchestrate`, `glazed signal` and `glazed status` use the `orchestrator` settings of the config; see [docs/orchestrator.md](docs/orchestrator.md).

The exit status of `glazed run` is 0 when every node completed, and 1 when a node failed a step (the other nodes still complete) or the arguments are invalid. Invalid configuration and failures of a batch step such as `publish` abort the run with an error. `glazed COMMAND --help` describes each command.

## Configuration

Configuration and inventory files are ProtoJSON of the messages in [`proto/glazed/v1`](proto/glazed/v1), with proto (snake_case) field names. Unknown fields are rejected, every message is checked against the `buf.validate` rules in its schema (violations are reported with their field paths, such as `workflows["daily"].steps[0].fetch.storage`), and relative paths resolve from the current directory. Secrets (`glazed.v1.SecretRef`) are written as `{"value": "..."}`, `{"env": "NAME"}`, `{"file": "/path"}` or `{"plugin": {...}}` (see [Extending](#extending)), and are resolved only when used.

### Inventory

`inventory` lists sources of nodes, and node names must be unique across all of them:

- `json_files`: `{"paths": ["inventory/*.json"]}` reads files of `glazed.v1.InventoryFile`, globs allowed
- `inline`: `{"defaults": {...}, "nodes": [...]}` is a `glazed.v1.InventoryFile` written in the config itself, to keep everything in one file
- `command`: `{"run": "bin/inventory", "timeout_seconds": 300}` runs a command with `/bin/sh -c` and reads the `glazed.v1.InventoryFile` it prints on stdout, for nodes kept in another system. A non-zero exit fails the run
- `plugin`: a provider from a plugin gem, see [Extending](#extending)

In both, `defaults` fill the fields each node leaves unset, with `params` and `secrets` merged key by key. Each node (`glazed.v1.Node`) has:

- `name` (required): unique name, also the storage key within its group
- `group`: storage key prefix, so files land at `<group>/<name>`
- `host` (default: `name`), `port` (default: the transport's standard port)
- `dialect` (required): see [Supported devices](#supported-devices)
- `transport` (default: `ssh`): `ssh` or `telnet`
- `username`, `password`
- `transport_options`: connection options per transport, replacing the one in `defaults` as a whole. `ssh` takes net-ssh options: `keys` (each `{"path": ...}` or `{"raw": <secret>}` holding the key text), `passphrase`, `keys_only`, `auth_methods`, `number_of_password_prompts`, `verify_host_key` (`HOST_KEY_VERIFICATION_NEVER`, `_ACCEPT_NEW`, `_ACCEPT_NEW_OR_LOCAL_TUNNEL` or `_ALWAYS`), `user_known_hosts_file`, `global_known_hosts_file`, `host_key`, `kex`, `encryption`, `hmac`, `compression`, `proxy_command`, `forward_agent` and `use_ssh_config` (default: `true`, reading `~/.ssh/config`). See `glazed.v1.SshOptions`
- `params`: dialect options, such as `"ios_rbac": "true"` to collect `show running-config view full`, or `"junos_license": "false"` to skip Junos license commands
- `secrets`: dialect secrets, such as `enable` for `ios` and `awplus`

### Storages

`storages` maps names to one backend each:

```jsonc
// git: a local working tree, initialised when missing; one commit per write
{"git": {"path": "/var/lib/glazed/raw", "branch": "main", "remote": "origin", "author_name": "glazed", "author_email": "glazed@localhost"}}

// github: commits through the Git Data API; the branch is created from base_branch (default: the repository default branch)
{"github": {"repository": "example/netconf", "branch": "glazed/auto", "base_branch": "main", "token": {"env": "GITHUB_TOKEN"}}}

// s3 (glazed-aws): one object per node; enable bucket versioning to keep history
{"s3": {"bucket": "example-netconf", "prefix": "raw/", "region": "us-west-2"}}

// filesystem: plain files under a directory, latest content only, for scripts and other tools
{"filesystem": {"path": "/var/lib/glazed/latest"}}

// memory: held by the glazed run process only, for raw configuration you do not want persisted at all
{"memory": {}}
```

For `git`, `branch` defaults to `main`, and `remote` is pulled before and pushed after each commit when set. For both `git` and `github`, `subdirectory` places files in a directory of the repository, such as `network/glazed`, instead of its root. For `github`, `api_url` points to GitHub Enterprise Server, and `author_name`/`author_email` override the token owner. For `s3`, the region defaults to the SDK's. `memory` content is gone when the process exits, so only steps of the same `glazed run` can read it; an orchestrator running steps as separate processes needs a persistent storage between them.

### Workflows

`workflows` maps names to ordered steps (`glazed.v1.Workflow`). Steps pass named artifacts, each a pointer into a named storage:

- `fetch` (per node): `{"output": "raw", "storage": "raw", "timeout_seconds": 60}` collects the configuration
- `redact` (per node): `{"input": "raw", "output": "redacted", "storage": "...", "redaction": {...}}` hides secrets. `redaction.mode` is `MODE_REMOVE` (default) or `MODE_HMAC`, which needs `hmac_key` holding the key in base64. `redaction.secrets` lists more secrets to hide besides those the dialect locates, each a `ref` (a `SecretRef`: `value`, `env`, `file` or a plugin source) such as `{"ref": {"env": "SNMP_COMMUNITIES"}, "delimiter": ","}`. Every occurrence of the referenced value in the configuration is hidden; with `delimiter`, the value is split into several secrets. With `"regexp": true` the value (or each split piece) is a regular expression instead and every match is hidden, as in `{"ref": {"value": "token-\\d+"}, "regexp": true}`. An entry's optional `note` (letters, digits and `_.@/-`) appears in its replacements, as `[~REDACTED:note=snmp~]` or `[~REDACTED:dgst=…:note=snmp~]`, to tell where an unobvious secret came from
- `publish` (batch): `{"input": "redacted", "storage": "team"}` writes the artifact of every node as one change, such as one commit naming the changed nodes
- `shell` (per node): `{"run": "sed -e '/^ntp clock-period/d'", "input": "raw", "output": "normalized", "storage": "...", "timeout_seconds": 300}` runs a command with `/bin/sh -c`. The input artifact's content is on stdin and stdout becomes the output artifact, both optional. `GLAZED_STEP`, `GLAZED_NODE_NAME`, `GLAZED_NODE_GROUP`, `GLAZED_NODE_DIALECT`, `GLAZED_NODE_HOST` and `GLAZED_NODE` (the node as ProtoJSON, secrets unresolved) are set, and a non-zero exit fails the node
- `batch_shell` (batch): `{"run": "bin/notify-changes"}` runs a command once, with the `glazed.v1.BatchState` of every node that got this far (artifacts and their `changed` flags) as ProtoJSON on stdin. A non-zero exit fails the run

`redaction` at the top level of the config holds the same settings for every `redact` step. A step's `mode` and `hmac_key` take precedence when set, and the `secrets` of both apply.

`jobs` (default: 4) sets how many nodes are processed in parallel. `requires` lists Ruby features to require before the rest of the config is decoded, which is how plugin gems are loaded.

## Extending

Inventory providers, storages, steps and secret sources each accept a `plugin` case: a `google.protobuf.Any` whose message type selects an implementation registered by another gem. The plugin gem ships its settings as a `.proto`, so they are typed and validated like glazed's own.

```protobuf
// proto/glazed_netbox/v1/netbox.proto in a plugin gem
syntax = "proto3";
package glazed_netbox.v1;
import "glazed/v1/secret.proto";

message NetboxInventory {
  string url = 1;
  glazed.v1.SecretRef token = 2;
}
```

```ruby
# lib/glazed_netbox.rb
require 'glazed/sources'
require 'glazed_netbox/v1/netbox_pb'

module GlazedNetbox
  class Source < Glazed::Sources::Base
    def self.from_proto(settings) = new(settings)

    def initialize(settings)
      super()
      @settings = settings
    end

    def nodes = [] # build Glazed::Proto::V1::Node messages from NetBox
  end

  Glazed::Sources.register(V1::NetboxInventory, Source)
end
```

The config then requires the gem and names the settings type with `@type`:

```jsonc
// glazed.json
{
  "requires": ["glazed_netbox"],
  "inventory": [{"plugin": {"@type": "type.googleapis.com/glazed_netbox.v1.NetboxInventory",
                            "url": "https://netbox.example.com", "token": {"env": "NETBOX_TOKEN"}}}]
}
```

Storages register with `Glazed::Storages.register` (a `Glazed::Storages::Base` wrapping its own location message in `glazed.v1.Pointer` with `pointer_to` and `location_of`), steps with `Glazed::Steps.register` (a `Glazed::Steps::NodeStep` or `BatchStep`), and secret sources with `Glazed::Secrets.register` (a `Glazed::Secrets::Base` returning the value). For changes too small for a gem, the `shell` and `batch_shell` steps run scripts instead.

## How it works

1. Consecutive per-node steps run for each node on a thread pool. A node that fails a step is reported and left out of the rest of the workflow.
2. A batch step runs once, with every node that completed the steps before it.
3. Every write compares content with what the storage already holds. Unchanged content is not written again, and the artifact records whether it changed.
4. Steps do not skip work because their input is unchanged, so a change that failed to publish once is published by the next run.

Steps take and return protobuf messages (`glazed.v1.NodeState`, `glazed.v1.BatchState`), and content never travels inline, only pointers. This is what lets each step run as its own state of an orchestrator, with per-node steps in a Map state and batch steps after it. glazed checks that a workflow is wired correctly before running it: every input produced by an earlier step, and every storage configured.

## Difference with Oxidized

- Oxidized keeps one copy of each configuration, optionally with secrets removed. glazed keeps the raw copy and a redacted copy in different storages with different audiences.
- Oxidized commits whatever it collects. glazed's GitHub storage commits to a topic branch meant for pull requests, so the history on the default branch can explain why each change was made.
- Oxidized is a daemon with a REST API and web UI (oxidized-web). glazed is a command and a set of building blocks, with steps defined as protobuf messages for external schedulers and orchestrators. `glazed orchestrate` fills Oxidized's role of polling nodes on an interval and after notifications, keeping its state in SQLite, optionally stored in S3, instead of serving an API.
- Oxidized models mix collection with per-run state. glazed dialects are declarations with inheritance, and per-run state lives in the run.
- Oxidized has years of production use behind it. Its models run on glazed through `glazed-oxidized`, redacted with patterns derived from their `cmd :secret` blocks.

## Caveats

- Not production-tested yet. The `ios` and `junos` dialects are tested against device captures from Oxidized's test suite; the `wlc`, `nec_ix` and `awplus` fixtures are written from command references and need checking against real devices.
- SSH host keys are verified with net-ssh's defaults and `~/.ssh/known_hosts` unless the node sets `transport_options.ssh.verify_host_key` or the known_hosts files.
- A node removed from the inventory leaves its file in the storages.
- Not yet available: opening pull requests automatically, and receivers turning syslog messages or SNMP traps into signals.

## Development

```
mise trust && mise install  # tools; mise.toml also lets bundler use platform gems (sorbet-static)
bundle install
(cd glazed && bundle exec rspec) && (cd glazed-aws && bundle exec rspec)
(cd glazed-oxidized && RUBY_BOX=1 bundle exec rspec)  # Ruby 4.0+
bundle exec srb tc          # inline RBS (#:) signatures, typed: strict
bin/check-docs              # YARD coverage must be 100%
hk check --all              # what CI lints: RuboCop, SPDX headers, Sorbet, YARD, buf, workflows
hk fix --all                # autocorrect what can be; `hk install` runs it as a pre-commit hook
```

After editing `proto/`, run `buf lint && buf generate && bin/tapioca dsl`. Dialect specs replay device sessions in Oxidized's simulation format under `glazed/spec/fixtures/dialects`; `GLAZED_UPDATE_GOLDEN=1 bundle exec rspec spec/glazed/dialects` rewrites the expected outputs for review.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/sorah/glazed.

## Acknowledgements

glazed builds on [Oxidized](https://github.com/ytti/oxidized). Its dialects are ported from Oxidized's models, and its dialect tests replay device captures from Oxidized's test suite. Thanks to Saku Ytti, Samer Abdel-Hafez and all Oxidized contributors. See [NOTICE](NOTICE) for details.

## License

This project is licensed under the Apache-2.0 License. See [LICENSE.txt](LICENSE.txt) and [NOTICE](NOTICE).

Copyright 2025-2026 Sorah Fukumori

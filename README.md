# glazed: Modern oxidized

This is a successor of oxidized, a network device configuration scraper. Offers these advantages:

- __Cloud native.__ Glazed offers storing into cloud storage, and run in cloud environment such as AWS Lambda.
- __Secret aware.__ Glazed allows saving raw configuration, and commiting reducted configuration to git for wider visibility. Reducted configuration can be configured by: remove entirely, or HMAC sum.
- __Git flow.__ Glazed allows commiting raw configuration to a dedicated repo for complete history, and commiting reducted configuration to a team-central repo on a topic branch, and developers can open a pull request once they completes a change, to clearly explain what has changed, and why.
- __Building blocks.__ Glazed offers well organized components so everyone can pick some of them as a building block. For instance, retrieving configuration, persisting configuration.
- __Device manifest (dialect api).__ Glazed provides oxidized like DSL but much better in term of inheritance, reusability, and internal structure. We'd like to avoid evaluating logics within Dialect itself.
  - __Oxidized compatible layer.__ Read device manifests from oxidized gem in Ruby::Box to dynamically translate to Glazed native manifests. (Low priority)

Priority: Oxidized compatible layer is ignorable for now. Initial device targets: Cisco IOS, Cisco WLC, Juniper, NEC IX

## Status

Working today: collecting from Cisco IOS/IOS XE, Cisco WLC (AireOS), Juniper Junos, NEC UNIVERGE IX and Allied Telesis AlliedWare Plus over SSH or Telnet; storing raw configuration in a local git repository or S3 (`glazed-aws`); publishing redacted configuration (secrets removed or replaced with an HMAC) to a local git repository or a GitHub repository branch.

Not yet: opening pull requests from the topic branch, daemon and AWS-native (Lambda + Step Functions) coordinators, schedule and notification (syslog, SNMP trap) triggers, the oxidized compatibility layer.

## Usage

```
gem install glazed            # plus glazed-aws for S3
glazed run -c glazed.json [--only NAME]... [--jobs N]
```

`glazed run` collects every node, writes each raw configuration to the raw storage, then publishes all redacted configurations in one commit. A node that fails is logged as a JSON line on stderr and skipped; the exit status is then 1.

Configuration and inventory files are ProtoJSON of the messages in [`proto/glazed/v1`](proto/glazed/v1), with proto (snake_case) field names. Unknown fields are rejected. Relative paths resolve from the current directory.

`glazed.json` (`glazed.v1.Config`):

```json
{
  "inventory": ["inventory/*.json"],
  "raw": {"s3": {"bucket": "netconf-raw", "prefix": "raw/"}},
  "redacted": {"github": {"repository": "example/netconf", "branch": "glazed/auto", "token": {"env": "GITHUB_TOKEN"}}},
  "redaction": {"mode": "MODE_HMAC", "hmac_key": {"env": "GLAZED_HMAC_KEY"}},
  "jobs": 8
}
```

`inventory/core.json` (`glazed.v1.InventoryFile`); `defaults` fill fields each node leaves unset:

```json
{
  "defaults": {"group": "core", "dialect": "ios", "username": "backup", "password": {"env": "BACKUP_PASSWORD"}},
  "nodes": [
    {"name": "rt1", "host": "192.0.2.1", "secrets": {"enable": {"file": "/run/secrets/enable"}}},
    {"name": "sw1", "dialect": "junos"},
    {"name": "wlc1", "dialect": "wlc", "transport": "telnet"}
  ]
}
```

Secrets (`glazed.v1.SecretRef`) are `{"value": ...}`, `{"env": ...}` or `{"file": ...}` and are resolved only when used.

Dialects are described in [docs/dialect-api.md](docs/dialect-api.md). The building blocks (`Glazed::Collector`, `Glazed::Redactor`, `Glazed::Storages`, `Glazed::Steps::Fetch` and `Publish`) are usable on their own.

## Development

```
mise trust && mise install  # tools; mise.toml also lets bundler use platform gems (sorbet-static)
bundle install
(cd glazed && bundle exec rspec) && (cd glazed-aws && bundle exec rspec)
bundle exec srb tc          # inline RBS (#:) signatures, typed: strict
bin/check-docs              # YARD coverage must be 100%
hk check --all              # what CI lints: RuboCop, SPDX headers, Sorbet, YARD, buf, workflows
hk fix --all                # autocorrect what can be; `hk install` runs it as a pre-commit hook
```

After editing `proto/`, run `buf lint && buf generate && bin/tapioca dsl`. Dialect specs replay device sessions in oxidized's simulation format under `glazed/spec/fixtures/dialects`; `GLAZED_UPDATE_GOLDEN=1 bundle exec rspec spec/glazed/dialects` rewrites the expected outputs for review.

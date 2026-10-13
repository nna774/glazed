## [Unreleased]

Initial release.

### Enhancements

- Collect configuration over SSH or Telnet, with dialects for Cisco IOS/IOS XE, Cisco WLC (AireOS), Juniper Junos, NEC UNIVERGE IX and Allied Telesis AlliedWare Plus, ported from Oxidized
- Class-based dialect DSL with inheritance ([docs/dialect-api.md](../docs/dialect-api.md))
- Redaction of the secrets a dialect locates: replaced with `[~REDACTED~]`, or with `[~REDACTED:dgst=…~]` carrying a keyed HMAC so changed secrets still show in diffs
- Storages: a local git repository, and a GitHub repository branch through the Git Data API. Unchanged content is not written again, and every write reports whether it changed
- Inventory from JSON files, the config itself, or a command printing it, through pluggable inventory providers
- Workflows of `fetch`, `redact` and `publish` steps passing artifacts between named storages, defined as protobuf messages (`glazed.v1`) so external orchestrators can run them
- `glazed run` command, running a workflow in-process
- `glazed orchestrate` command, running workflows for each node on their own intervals and after signals with trailing debounce, with state in a pluggable state backend ([docs/orchestrator.md](../docs/orchestrator.md))
- `glazed signal` command, making nodes due soon from scripts or notification receivers
- `sqlite` state backend, kept in a local file or in any storage supporting conditional writes (`filesystem`, `memory`, glazed-aws's `s3`)

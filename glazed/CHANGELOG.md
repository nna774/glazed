## [Unreleased]

Initial release.

### Enhancements

- Collect configuration over SSH or Telnet, with dialects for Cisco IOS/IOS XE, Cisco WLC (AireOS), Juniper Junos, NEC UNIVERGE IX and Allied Telesis AlliedWare Plus, ported from Oxidized
- Class-based dialect DSL with inheritance ([docs/dialect-api.md](../docs/dialect-api.md))
- Redaction of the secrets a dialect locates: removed, or replaced with a keyed HMAC so changed secrets still show in diffs
- Storages: a local git repository, and a GitHub repository branch through the Git Data API. Unchanged content is not written again, and every write reports whether it changed
- Inventory from JSON files, through pluggable inventory providers
- Workflows of `fetch`, `redact` and `publish` steps passing artifacts between named storages, defined as protobuf messages (`glazed.v1`) so external orchestrators can run them
- `glazed run` command, running a workflow in-process

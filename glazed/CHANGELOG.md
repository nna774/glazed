## [Unreleased]

### Enhancements

- Redaction hides additional secrets given as secret references, as literal text or regular expressions and optionally split by a delimiter, in a `redact` step or in the top-level `redaction` shared by all of them
- Storages: `subdirectory` for `git` and `github` places files in a directory of the repository instead of its root
- `glazed signal --all`, and `all_nodes` and `workflows` on `glazed.v1.Signal`, signal every node of chosen workflows, for scheduled runs
- `Glazed::Coordinator` and the `glazed.v1.CoordinatorTask` protocol let an external coordinator, such as AWS Step Functions with glazed-aws, drive the orchestrated workflows one step at a time
- `sqlite` state backend: schema version 2 keeps the waiting coordinator execution. Version 1 databases are upgraded on first use, after which glazed 0.1.0 refuses them

## [0.1.0] - 2026-10-14

Initial release.

### Enhancements

- Collect configuration over SSH or Telnet, with dialects for Cisco IOS/IOS XE, Cisco WLC (AireOS), Juniper Junos, NEC UNIVERGE IX and Allied Telesis AlliedWare Plus, ported from Oxidized
- Class-based dialect DSL with inheritance ([docs/dialect-api.md](../docs/dialect-api.md))
- Redaction of the secrets a dialect locates: replaced with `[~REDACTED~]`, or with `[~REDACTED:dgst=…~]` carrying a keyed HMAC so changed secrets still show in diffs
- Storages: a local git repository, and a GitHub repository branch through the Git Data API. Unchanged content is not written again, and every write reports whether it changed
- Inventory from JSON files, the config itself, or a command printing it, through pluggable inventory providers
- Workflows of `fetch`, `redact` and `publish` steps passing artifacts between named storages, defined as protobuf messages (`glazed.v1`) so external orchestrators can run them
- `glazed run` command, running a workflow in-process
- `GLAZED_CONFIG_FILE` names the config file when `-c` is omitted
- `glazed orchestrate` command, running workflows for each node on their own intervals and after signals with trailing debounce, with state in a pluggable state backend ([docs/orchestrator.md](../docs/orchestrator.md))
- `glazed signal` command, making nodes due soon from scripts or notification receivers
- `glazed status` command, showing when each node runs next and how its last run went, exiting 1 when one is failing or overdue
- `sqlite` state backend, kept in a local file or in any storage supporting conditional writes (`filesystem`, `memory`, glazed-aws's `s3`)

# Running the glazed orchestrator

`glazed orchestrate` keeps running and runs workflows for each node when the node is due. For each orchestrated workflow, a node is due:

- right after it appears in the inventory,
- an interval after its last run finished, and
- shortly after a signal, such as `glazed signal sw1` sent when the device's configuration changed.

It is an ordinary foreground process. It does not fork, write a pid file or redirect its output; it logs JSON lines on stderr like `glazed run`, and is meant to run under systemd or a container runtime.

## Configuration

Add `orchestrator` to the config (`glazed.v1.Orchestrator` in [`proto/glazed/v1/orchestrator.proto`](../proto/glazed/v1/orchestrator.proto)):

```json
{
  "inventory": [{"json_files": {"paths": ["inventory.json"]}}],
  "storages": {
    "vault": {"git": {"path": "/var/lib/glazed/vault"}},
    "team": {"git": {"path": "/var/lib/glazed/team"}}
  },
  "workflows": {
    "backup": {"steps": [
      {"name": "fetch", "fetch": {"output": "raw", "storage": "vault"}},
      {"name": "publish", "publish": {"input": "raw", "storage": "team"}}
    ]},
    "audit": {"steps": [
      {"name": "check", "batch_command": {"run": "/usr/local/bin/audit-configs"}}
    ]}
  },
  "orchestrator": {
    "state": {"sqlite": {"path": "/var/lib/glazed/state.sqlite3"}},
    "workflows": {
      "backup": {
        "schedule": {"interval_seconds": 3600, "retry_interval_seconds": 600, "jitter_seconds": 300},
        "debounce": {"delay_seconds": 60, "max_wait_seconds": 600}
      },
      "audit": {"schedule": {"interval_seconds": 86400}}
    }
  }
}
```

| Field | Default | Meaning |
|---|---|---|
| `state` | (required) | Where due dates and run results of every workflow are kept; see [State](#state) |
| `workflows` | (required) | Workflows to run, by name in the config's `workflows`, each with the settings below |
| `poll_seconds` | 30 | Seconds between checks of the state for due nodes |
| `inventory_refresh_seconds` | 300 | Seconds between inventory reloads |

Each workflow's settings (`glazed.v1.Orchestration`):

| Field | Default | Meaning |
|---|---|---|
| `schedule.interval_seconds` | 3600 | Seconds from a successful run finishing to the next run |
| `schedule.retry_interval_seconds` | `interval_seconds` | Seconds from a failed run finishing to the next run |
| `schedule.jitter_seconds` | 0 | Up to this many seconds are added at random, spreading nodes over time |
| `debounce.delay_seconds` | 60 | Seconds a signal waits for further signals |
| `debounce.max_wait_seconds` | 600 | Seconds after the first signal by which the node runs |
| `batch_size` | unlimited | Nodes run together at most |
| `lease_seconds` | 3600 | Seconds a node stays claimed by an orchestrator; must exceed the time a batch takes |

Each workflow keeps its own due dates. Nodes of a workflow due at the same time run together as one batch, so a `publish` step writes all of them in one commit. Workflows take turns, one batch at a time, so while a batch runs, nodes becoming due wait for the next turn. A workflow removed from `orchestrator.workflows` leaves its records in the state, unused.

## Signals

```
glazed signal -c glazed.json [-w WORKFLOW,...] [--source SOURCE] [--now] (NAME... | --all)
```

`glazed signal` records the signal in the state for every orchestrated workflow, or those given with `-w`, and prints when each node is due in each; the orchestrator does not need to be reachable. `--all` signals every node in the inventory instead of the named ones. `--source` is recorded as the reason the node is due (default `manual`), and `--now` skips the debounce delay.

Signals are debounced on the trailing edge: with each workflow's `debounce`, each one makes the node due `delay_seconds` after it, but no later than `max_wait_seconds` after the first signal not yet followed by a run. A burst of syslog messages during a configuration session therefore produces one run after the session goes quiet, and a session that never goes quiet still runs every `max_wait_seconds`. A scheduled run due earlier is kept. A signal received while the node is running makes it due again after the run.

Other programs, such as a syslog or SNMP trap receiver, can send signals by running `glazed signal`, or from Ruby with `Glazed::Coordinator#signal`, which takes `glazed.v1.Signal` messages. A signal names one `node` or sets `all_nodes`, and may list the `workflows` it applies to.

## Status

```
$ glazed status
WORKFLOW  NODE    STATUS   DUE                     REASON    LAST RUN                    RESULT
audit     sayaka  overdue  17:37:54Z (13m39s ago)  schedule  17:37:14Z (0.0s)            ok         signal pending since 17:42:02Z
backup    fw1     waiting  17:51:02Z (in 8m52s)    retry     17:41:02Z (20.1s)           failed ×3  fetch: timed out waiting for prompt
backup    sw1     running  17:41:50Z               syslog    17:41:51Z (running)         -          lease mafuyu:51753:a003… until 18:41:51Z
```

`glazed status` prints each workflow's records from the state. STATUS is `running` while an orchestrator holds the node's lease, `overdue` when it has been due for longer than `poll_seconds` (usually because no orchestrator is running), `due` when it is due within that, and `waiting` otherwise. Times are UTC, with the date only when it is not today.

- `-w WORKFLOW,...` and `--only NAME,...` narrow the list, and `--failing` shows only nodes whose last run failed.
- `--json` prints each record as a line of ProtoJSON of `glazed.v1.NodeSchedule` instead.
- The exit status is 1 when a listed node is failing or overdue, so the command can serve as a monitoring check.

## State

The state holds one `glazed.v1.NodeSchedule` per workflow and node: its due date and why, the last run's times and result, and which orchestrator is running it.

With `{"sqlite": {"path": "..."}}`, the state is a local SQLite file. The orchestrator and `glazed signal` on the same host share it through SQLite's locking.

With `{"sqlite": {"storage": "state", "key": "glazed/state.sqlite3"}}`, the database is kept in a storage that supports conditional writes: `s3` (glazed-aws), `filesystem` or `memory`. Each process works on a private copy:

1. Before each change or read, it checks the version in the storage, and downloads the database again when another process uploaded a newer one.
2. It makes the change in a transaction.
3. It uploads the database, conditional on the storage still holding the version the change was made on (`If-Match` on S3).
4. If another process uploaded first, it downloads the newer database and makes the change again, up to 5 times.

Checks that change nothing do not upload. This lets `glazed signal` run on another host than the orchestrator, and lets a replacement orchestrator pick up where a lost one stopped.

Other state backends, such as one native to AWS, implement `Glazed::StateBackends::Base` and are selected with `{"plugin": {"@type": ...}}` like other plugins.

## Running under systemd

```ini
# glazed-orchestrate.service
[Unit]
Description=glazed orchestrator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=glazed
EnvironmentFile=/etc/glazed/env
ExecStart=/usr/local/bin/glazed orchestrate -c /etc/glazed/glazed.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
TimeoutStopSec=15min

[Install]
WantedBy=multi-user.target
```

- TERM or INT stops the orchestrator after the current batch. A second one interrupts the batch, releasing its nodes so they run again soon. `TimeoutStopSec` should cover a batch.
- HUP reloads the inventory before the next batch, logging `inventory loaded` with the node count.
- The first inventory load must succeed. Later reload failures are logged and the previous inventory is kept.
- A failure of the state backend, such as S3 being unreachable, stops the orchestrator with an error, and `Restart=on-failure` starts it again.

## Running more than one orchestrator

Orchestrators sharing a state lease each node before running it, so a node runs on one orchestrator at a time. A node leased by an orchestrator that died runs again after `lease_seconds`. With a SQLite state kept in S3, every lease and every result is an upload of the whole database, so this suits a standby orchestrator or a few orchestrators better than many.

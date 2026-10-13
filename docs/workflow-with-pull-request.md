# Workflow: S3 archive with pull requests on GitHub

This example keeps every collected configuration in S3, raw and redacted, and continuously pushes the redacted configuration to a branch of a team repository on GitHub. Engineers open a pull request from that branch whenever they finish a change, so the history on the default branch records not only what changed but also why.

```
devices ──fetch──▶ S3 raw/ ──redact──▶ S3 redacted/ ──publish──▶ GitHub glazed/auto ──PR (human)──▶ main
```

## Requirements

- `glazed` and `glazed-aws` (for the `s3` storage).
- An S3 bucket with versioning enabled. Pointers record the object version written, and versioning keeps the history of raw configuration, which never leaves S3.
- AWS credentials through the SDK's default chain, allowed `s3:PutObject` on both prefixes, and `s3:GetObject` and `s3:GetObjectVersion` on `redacted/`.
- A GitHub repository whose default branch is `main`, and a token (a fine-grained personal access token, or a GitHub App installation token) with Contents read and write permission on it. glazed only writes to its own branch, so `main` can be protected to require pull requests.
- In the repository settings, enable "Automatically delete head branches". See [Branch lifecycle](#branch-lifecycle) for why.

## Configuration

`glazed.json`:

```json
{
  "inventory": [{"json_files": {"paths": ["inventory/*.json"]}}],
  "storages": {
    "raw": {"s3": {"bucket": "example-netconf", "prefix": "raw/"}},
    "redacted": {"s3": {"bucket": "example-netconf", "prefix": "redacted/"}},
    "team": {"github": {
      "repository": "example/netconf",
      "branch": "glazed/auto",
      "base_branch": "main",
      "token": {"env": "GITHUB_TOKEN"},
      "author_name": "glazed",
      "author_email": "glazed@example.com"
    }}
  },
  "workflows": {
    "sync": {"steps": [
      {"name": "fetch", "fetch": {"output": "raw", "storage": "raw"}},
      {"name": "redact", "redact": {
        "input": "raw", "output": "redacted", "storage": "redacted",
        "redaction": {"mode": "MODE_HMAC", "hmac_key": {"env": "GLAZED_HMAC_KEY"}}
      }},
      {"name": "publish", "publish": {"input": "redacted", "storage": "team"}}
    ]}
  },
  "jobs": 8
}
```

`inventory/core.json`:

```json
{
  "defaults": {"group": "core", "username": "backup", "password": {"env": "BACKUP_PASSWORD"}},
  "nodes": [
    {"name": "rt1", "host": "192.0.2.1", "dialect": "ios", "secrets": {"enable": {"env": "ENABLE_SECRET"}}},
    {"name": "sw1", "host": "192.0.2.2", "dialect": "junos"}
  ]
}
```

What each step does on every run:

1. `fetch` logs into each node and writes its configuration to `s3://example-netconf/raw/core/<node>`.
2. `redact` reads that object, replaces each secret located by the dialect with `<secret hmac:…>`, and writes `s3://example-netconf/redacted/core/<node>`.
3. `publish` commits the redacted configuration of every node that got this far to `glazed/auto` as one commit, `publish: update rt1, sw1`. Nothing is committed when no configuration changed, so the branch only moves when a device changed.

With `MODE_HMAC`, a changed secret still shows up in the diff without being revealed. Keep `GLAZED_HMAC_KEY` stable: a new key changes every digest at once. Use `MODE_REMOVE` to hide secrets entirely.

## Running it continuously

Run the workflow on a schedule. With cron:

```
*/15 * * * * glazed run -c /etc/glazed/glazed.json -w sync 2>>/var/log/glazed.jsonl
```

Or with a systemd timer:

```ini
# glazed-sync.service
[Service]
Type=oneshot
EnvironmentFile=/etc/glazed/env
ExecStart=/usr/local/bin/glazed run -c /etc/glazed/glazed.json -w sync

# glazed-sync.timer
[Timer]
OnCalendar=*:0/15
[Install]
WantedBy=timers.target
```

The environment file provides `GITHUB_TOKEN`, `GLAZED_HMAC_KEY`, `BACKUP_PASSWORD` and `ENABLE_SECRET`. Each run logs one JSON line per node and step on stderr. A node that fails is skipped for that run and does not hold back the others; the exit status is then 1, which is worth alerting on.

## Opening the pull request

1. An engineer changes a device, for example adding a VLAN on `sw1`.
2. Within one schedule interval, `glazed/auto` receives a commit containing the change.
3. When the change is complete, which may span several devices and runs, the engineer opens a pull request from `glazed/auto` into `main`. The title and description say what was changed and why, and can link the ticket or maintenance window.
4. Reviewers read the diff of the redacted configuration and approve.
5. The pull request is merged with any merge method. With "Automatically delete head branches" enabled, `glazed/auto` is deleted.

Until the pull request is merged, later runs keep adding commits to the same branch, so the open pull request always shows everything that differs from `main`. Merge promptly after a change is done, so unrelated changes by other engineers don't end up in the same pull request. If they do, say so in the description, or wait for the other change to finish and describe both.

## Branch lifecycle

On each publish, the GitHub storage commits on top of `glazed/auto`. When the branch does not exist, it creates it from `base_branch` (`main`). Deleting the branch after each merge therefore starts the next round from the merged state:

- After a squash or rebase merge, the old branch still holds commits that `main` does not have. Committing on top of it would make the next pull request show the already-merged changes again.
- After a merge commit, keeping the branch would work, but deleting it is still simpler.

If the branch was not deleted, delete it by hand before the next run.

## Limitations

- A node removed from the inventory leaves its file in the repository. Delete it in a pull request of its own.
- The commit message lists every node published in that run, not only those whose configuration changed. The diff shows what changed.
- glazed does not open pull requests itself.

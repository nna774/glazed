# Running glazed on AWS Step Functions

glazed-aws runs the orchestrated workflows of a config (the `orchestrator` settings of [docs/orchestrator.md](orchestrator.md)) on AWS Step Functions instead of a long-running `glazed orchestrate`. Each workflow step is a state of a Standard state machine, and each state invokes one AWS Lambda function that performs a single task. Due dates, debounce and leases behave as under `glazed orchestrate`, and `glazed status` reads the same state.

```
EventBridge rule ──┐ (syslog, config change events)
EventBridge Pipe ──┼─▶ StartExecution ─▶ Check ─▶ end
Scheduler (cron) ──┘   (signals as input)   │ wait_until
                                            ▼
                                          Sleep (Wait)
                                            ▼
                     Prepare ─▶ Workflows (Parallel: per-node steps in a Map, batch steps once) ─▶ Complete
                        ▲                                                                       │
                        └──────────────────────────── Check again ◀────────────────────────────┘
```

## How executions run

Executions are started only from outside glazed. Every execution carries signals in its input, possibly none:

- An EventBridge rule targeting the state machine. The event's `detail` is a `glazed.v1.Signal`. The Signal's `source` and `received_at` default to the event's `source` and `time`.
- An EventBridge Pipe from an SQS queue. Each message body is a Signal or an EventBridge event.
- EventBridge Scheduler, with input `{"signals": [...]}`. Use a cron schedule for scheduled runs such as a daily 04:00 backup, and a `rate()` schedule with input `{}` as a safety net (see below).

Every execution starts with **Check**:

1. Check loads the inventory, adding new nodes and deleting removed ones, and applies the signals.
2. It finds the earliest time a node becomes due.
3. The state keeps one *waiter*: the execution that sleeps until that time. If another live waiter wakes at that time or earlier, this execution ends at once. Otherwise it becomes the waiter, and a Wait state sleeps until the time. A Standard workflow costs nothing while it waits.

After waking, **Prepare** leases the due nodes of every workflow. Then each workflow's branch runs its steps:

- Consecutive per-node steps run in a Map over the nodes, one Lambda invocation per node and step.
- Batch steps such as `publish` run once with every node that has not failed.

**Complete** records the outcomes and schedules each node's next run. The execution then goes back to Check, so it stays the waiter for the next due node: a retry, a signal that arrived during the run, or the next interval.

A node that fails a step, through an error or a Lambda timeout, is carried to Complete as failed; the other nodes go on. A failed batch step fails every node of the batch.

### Signals before, during and after a run

Settings: workflow `backup` (fetch, redact, publish) with `debounce {delay_seconds: 60, max_wait_seconds: 600}`, a daily cron signal at 04:00, and syslog signals for sw1.

| Time | Trigger | Execution | What happens |
|---|---|---|---|
| 04:00:00 | cron `daily` (`all_nodes`, `immediate`) | E1 | Every node is due now. E1 becomes the waiter, wakes at once, leases rt1 and sw1, and starts fetching. |
| 04:00:20 | syslog sw1 | E2 | sw1 is running, so the signal makes it due again after the run: 04:01:20. E1 is a live waiter, so E2 ends. |
| 04:00:40 | syslog sw1 | E3 | sw1 is now due at 04:01:40 (trailing debounce). E3 ends. |
| 04:00:55 | (E1 completes) | E1 | rt1 is due tomorrow. sw1 keeps 04:01:40, as the signal came after its run started. E1 waits until 04:01:40. |
| 04:01:10 | syslog sw1 | E4 | sw1 is now due at 04:02:10. E1 already waits, and earlier, so E4 ends. |
| 04:01:40 | (E1 wakes) | E1 | Nothing is due yet. E1 waits until 04:02:10, at least `poll_seconds` later. |
| 04:02:10 | (E1 wakes) | E1 | sw1 runs once for all three signals. E1 then waits for tomorrow's runs. |

When signals never stop, `max_wait_seconds` caps the delay: a node signalled every 20s from 10:00:00 still runs at 10:10:00.

### When there is no waiter

An execution stops waiting after `--max-cycles` cycles (20 by default), which keeps its history within the Step Functions limit, or when it fails. Its waiter record expires after the grace period. By default that is the longest `lease_seconds`, so that a waiter busy running a batch still counts as live.

Until the next execution starts, nothing wakes for due nodes. Any signal starts one, and so does a `rate()` schedule. A `rate(1 hour)` schedule with input `{}` bounds how late an interval or retry run can be after a waiter is lost.

## Setting up

### Lambda function

The prebuilt container image `ghcr.io/sorah/glazed-lambda` holds glazed, glazed-aws and glazed-oxidized with Oxidized's models; see [glazed-aws/lambda](../glazed-aws/lambda/README.md). Lambda runs images from Amazon ECR only, so push it, or an image built from it, to an ECR repository. Alternatively, the function can run on the Ruby 4.0 runtime from a zip with vendored gems.

- **Handler:** `glazed/aws/lambda.Glazed::Aws::Lambda.handler`, or `glazed_lambda_entrypoint.Glazed::Aws::Lambda.handler` in the image
- **Config:** an S3 object, or a file in the function; see [Config](#config).
- **Secrets:** keep them in Parameter Store as SecureString parameters and refer to them as `{"ssm": {"name": "/glazed/backup/password"}}`, rather than in the function's environment variables, which anyone allowed `lambda:GetFunctionConfiguration` can read. A warm function reuses a fetched value for `cache_seconds` (default 300), so a rotated value is picked up within that time and without a deploy.
- **Timeout:** enough for the slowest node of the slowest step. Each invocation runs one step for one node, or one batch step.
- **Network:** reach the devices, for example by placing the function in a VPC.
- **Logs:** JSON lines on standard error, in CloudWatch Logs.

Storages must outlive one invocation, because each step may run in another Lambda instance:

- Use `s3` or `github`.
- `memory` storages are refused.
- `filesystem` storages, and `git` storages without `remote`, are warned about.

Keep the state in S3: `{"sqlite": {"storage": "state", "key": "glazed/state.sqlite3"}}`.

### Config

Keep the config in S3 to change it without building an image, with these environment variables of the function:

| Variable | Meaning |
|---|---|
| `GLAZED_CONFIG_S3_BUCKET` | Bucket of the config object |
| `GLAZED_CONFIG_S3_KEY` | Key of the config object |
| `GLAZED_CONFIG_S3_DIGEST` | SHA-256 of the object in base64 |
| `GLAZED_CONFIG_S3_REGION` | Region of the bucket; the function's region when unset |

The function reads the object once per execution environment and refuses it unless its SHA-256 matches `GLAZED_CONFIG_S3_DIGEST`. To change the config, upload the object and then update the digest. Updating an environment variable replaces every execution environment, so every task afterwards runs with the new config, and an object uploaded without updating the digest is never used. With Terraform, the digest of a local file is `filebase64sha256("glazed.json")`, and `openssl dgst -sha256 -binary glazed.json | base64` prints it.

Paths in the config, such as `json_files` inventory, are still read from the function's file system. Keep the inventory in the config with `inline`, or load it with a `command` source.

Otherwise, the config is the file `GLAZED_CONFIG_FILE` names, which the image sets to `/var/task/glazed.json`. Build an image that adds it:

```dockerfile
FROM ghcr.io/sorah/glazed-lambda:2026.10.14.01
COPY glazed.json /var/task/glazed.json
```

Changing workflows or their steps also needs the state machine definition generated again (see [State machine](#state-machine)). Other settings, such as the inventory, schedules and storages, take effect with the config alone.

IAM permissions:

- **The function:** S3 read and write for the state and the storages, `s3:GetObject` on the config object, `ssm:GetParameter` on the secret parameters, and `kms:Decrypt` on the key encrypting them when it is not the AWS managed key.
- **The state machine role:** `lambda:InvokeFunction` on the function.
- **The roles of EventBridge rules, Pipes and Scheduler schedules:** `states:StartExecution` on the state machine.

glazed itself never starts executions or changes schedules.

### State machine

```
glazed-aws state-machine -c glazed.json --function-arn arn:aws:lambda:REGION:ACCOUNT:function:glazed > glazed.asl.json
```

This prints the Amazon States Language definition of a Standard state machine for the config's orchestrated workflows. Regenerate it when workflows or their steps change.

| Option | Default | Meaning |
|---|---|---|
| `--max-concurrency N` | `jobs` of the config, or 4 | Nodes processed in parallel by each Map |
| `--grace-seconds N` | longest `lease_seconds` | Seconds after a waiter's wake time until another execution may take over |
| `--max-cycles N` | 20 | Cycles after which an execution ends |

### Triggers

An EventBridge rule passing signals from your own events:

```json
{"source": ["netops.syslog"], "detail-type": ["glazed signal"]}
```

```
aws events put-events --entries '[{"Source": "netops.syslog", "DetailType": "glazed signal", "Detail": "{\"node\": \"sw1\"}"}]'
```

An EventBridge Scheduler schedule for a daily run of every node:

```json
{
  "ScheduleExpression": "cron(0 4 * * ? *)",
  "Target": {
    "Arn": "arn:aws:states:REGION:ACCOUNT:stateMachine:glazed",
    "RoleArn": "arn:aws:iam::ACCOUNT:role/glazed-scheduler",
    "Input": "{\"signals\": [{\"all_nodes\": true, \"workflows\": [\"backup\"], \"source\": \"daily\", \"immediate\": true}]}"
  }
}
```

The safety net is the same schedule with `rate(1 hour)` and input `{}`.

## Settings that behave differently

- **`poll_seconds`** is the shortest time a waiter sleeps between cycles, so a node signalled again and again does not make it spin.
- **`inventory_refresh_seconds`** does not apply. The inventory loads on every Check and Prepare.
- **`batch_size`** also bounds the size of the data passed between states. Keep a batch under the 256 KiB Step Functions payload limit, roughly a few hundred nodes.
- **`lease_seconds`** must cover a whole cycle of a batch: every step for every node.

`glazed signal` from a shell records signals in the state but starts no execution. Its signals run when the waiter wakes, or at the next execution. Send signals through EventBridge to have them run on time.

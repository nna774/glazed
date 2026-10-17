## [0.3.0] - 2026-10-17

### Breaking changes

- The function needs `states:DescribeExecution` on the executions of the state machine. Generate the state machine definition again: Check passes the execution ARN as its token

### Bug fixes

- A waiter execution that failed or was stopped no longer holds off other executions, and the signals they carry, until its record expires; Check looks up the waiter's execution before deferring to it

## [0.2.0] - 2026-10-15

### Enhancements

- The Lambda function returns the state machine definition for the event `{"state_machine": {}}`, so Terraform can generate it with `aws_lambda_invocation`
- `ssm` secret source: `{"ssm": {"name": ...}}` reads an AWS Systems Manager Parameter Store parameter, decrypted, and reuses it for `cache_seconds`
- The Lambda function reads its config from S3 with `GLAZED_CONFIG_S3_BUCKET`, `GLAZED_CONFIG_S3_KEY` and `GLAZED_CONFIG_S3_DIGEST`, checking the object's SHA-256
- Run the orchestrated workflows on AWS Step Functions: a Lambda function performing each task (`Glazed::Aws::Lambda`), and `glazed-aws state-machine` printing the state machine definition. Signals come from EventBridge rules, Pipes and Scheduler, and debounce waits in the state machine ([docs/aws-step-functions.md](../docs/aws-step-functions.md))

## [0.1.0] - 2026-10-14

Initial release.

### Enhancements

- `s3` storage: skips content identical to the stored object by SHA-256 checksum, and writes conditionally (`If-Match`/`If-None-Match`) so concurrent writers are never overwritten unseen
- `s3` storage supports conditional writes by ETag, so it can hold the `sqlite` state of `glazed orchestrate`

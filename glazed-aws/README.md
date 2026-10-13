# glazed-aws

AWS integrations for [glazed](https://github.com/sorah/glazed): the `s3` storage (`Glazed::Storages::S3`). Installing this gem makes `{"s3": {...}}` storage configs available.

It also runs the orchestrated workflows of a config on AWS Step Functions with a Lambda function (`Glazed::Aws::Lambda`), and the `glazed-aws state-machine` command prints the state machine definition. See [docs/aws-step-functions.md](../docs/aws-step-functions.md).

# glazed Lambda container image

A container image of the AWS Lambda function that runs glazed's orchestrated workflows on AWS Step Functions. See [docs/aws-step-functions.md](../../docs/aws-step-functions.md) for the state machine and its triggers.

## Image

`ghcr.io/sorah/glazed-lambda` holds glazed, glazed-aws and glazed-oxidized, built from one commit of this repository:

- `:YYYY.MM.DD.NN` and `:latest`, released by pushing a `lambda/YYYY.MM.DD.NN` tag, such as `lambda/2026.10.14.01`
- `:main` and `:<commit SHA>`, built from every commit to `main`

Image releases are independent of the gem releases, so a change to any of the gems can ship in an image.

- **Handler:** `glazed_lambda_entrypoint.Glazed::Aws::Lambda.handler`, the image's default command
- **Config:** `GLAZED_CONFIG_FILE` defaults to `/var/task/glazed.json`
- **Oxidized models:** `oxidized_*` dialects work (`RUBY_BOX=1` is set) once the config requires `glazed/oxidized`. Models come from Oxidized 0.32.2 in `/var/task/oxidized/model` (`OXIDIZED_HOME`), where a model of the same name replaces one
- **`HOME`:** `/tmp`, the only writable directory on Lambda, for `~/.ssh/known_hosts`

## Usage

Build an image adding the config, and any plugin gems or models:

```dockerfile
FROM ghcr.io/sorah/glazed-lambda:2026.10.14.01
COPY glazed.json /var/task/glazed.json
COPY models/ /var/task/oxidized/model/
```

Lambda runs images from Amazon ECR only. Push the image to an ECR repository, or pull ghcr.io images through an [ECR pull through cache rule](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html) whose upstream is `ghcr.io`, which needs GitHub credentials in Secrets Manager even for public images.

## Building

Run the following at the repository root:

```
docker build -f glazed-aws/lambda/Dockerfile .
```

Gems are installed from [Gemfile.lock](Gemfile.lock); update it with `bundle lock --update` in this directory.

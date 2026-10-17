---
name: releng
description: Release engineering for glazed. Bump versions of glazed, glazed-aws and glazed-oxidized, write the `releng: <version>` commit, create signed tags (`<gem>/v<version>`, `lambda/YYYY.MM.DD.NN`) and push them so the release workflow publishes gems and the Lambda image. Use whenever the user asks to release, cut a version, bump versions, tag, publish gems, or ship a new Lambda container image, even if they do not say "releng".
---

# glazed release engineering

Three gems are released together at the same version: `glazed`, `glazed-aws`, `glazed-oxidized`. The Lambda container image is versioned separately by CalVer. Use `git show 3dafea1` (0.3.0) as the reference release commit. Commit or push only when the user has asked for it.

## 1. Release commit

Check `git branch --show-current` first; releases are committed directly on `main`. Subject is `releng: <version>`, body e.g. "glazed-aws and glazed-oxidized require glazed ~> X.Y.0.", then the Co-Authored-By line. Touch:

- `glazed/lib/glazed/version.rb`, `glazed-aws/lib/glazed/aws/version.rb`, `glazed-oxidized/lib/glazed/oxidized/version.rb`: `VERSION = '...'`.
- `spec.add_dependency "glazed", "~> X.Y.0"` in `glazed-aws/glazed-aws.gemspec` and `glazed-oxidized/glazed-oxidized.gemspec`.
- `Gemfile.lock`: run `bundle install --local`.
- `glazed-aws/lambda/Gemfile.lock`: edit by hand (three gem versions, the `glazed (~> X.Y.0)` lines, and the CHECKSUMS entries for the three gems).
- Each gem's `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`. `glazed-oxidized` may lack an Unreleased section; add `## [X.Y.Z] - date` with at least "Require glazed X.Y.Z.". The release workflow fails without a `## [VERSION]` section.

The hk commit hooks run rubocop, sorbet and yard; fix failures rather than skipping hooks.

## 2. Tags

All tags are GPG-signed annotated tags on the release commit. If signing fails with an ioctl error, ask the user to unlock their key.

```
git tag -s glazed/vX.Y.Z -m "glazed X.Y.Z"
git tag -s glazed-aws/vX.Y.Z -m "glazed-aws X.Y.Z"
git tag -s glazed-oxidized/vX.Y.Z -m "glazed-oxidized X.Y.Z"
git tag -s lambda/YYYY.MM.DD.NN -m "lambda YYYY.MM.DD.NN"
```

`NN` is a two-digit counter starting at `01` per day; check `git tag -l 'lambda/*'`. Skip the lambda tag if no image is wanted.

## 3. Push

GitHub triggers no tag-push workflows when more than 3 tags are pushed in one push (all four at once triggered nothing on 2026-10-17). Push `main` first, then each tag alone, in order glazed, glazed-aws, glazed-oxidized, lambda, with a few seconds between:

```
git push origin main
git push origin refs/tags/glazed/vX.Y.Z
...
```

If a push triggered nothing, delete those tags from origin (`git push origin :refs/tags/<tag>`) and re-push one at a time.

## 4. Monitor

```
gh run list -R sorah/glazed --workflow release --limit 6
gh run watch -R sorah/glazed <run-id>
```

- Gem jobs: run tests, create a draft GitHub release from the CHANGELOG section, publish to RubyGems. Environment `rubygems-org` may wait for approval by the human.
- Lambda job: builds and pushes `ghcr.io/sorah/glazed-lambda:<version>` and `:latest`, creates a draft release.
- Draft releases must be published by the human.

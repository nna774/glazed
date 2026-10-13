## [Unreleased]

Initial release.

### Enhancements

- `s3` storage: skips content identical to the stored object by SHA-256 checksum, and writes conditionally (`If-Match`/`If-None-Match`) so concurrent writers are never overwritten unseen

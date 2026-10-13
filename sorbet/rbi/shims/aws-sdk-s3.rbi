# typed: strict

# SPDX-License-Identifier: Apache-2.0

# aws-sdk-s3 defines response types as Struct.new(...) members, which tapioca
# does not see.

class Aws::S3::Types::HeadObjectOutput
  sig { returns(T.nilable(String)) }
  def checksum_sha256; end

  sig { returns(T.nilable(String)) }
  def etag; end

  sig { returns(T.nilable(String)) }
  def version_id; end
end

# typed: strict

# SPDX-License-Identifier: Apache-2.0

# google-protobuf defines the well-known type helpers in plain Ruby without signatures.

class Google::Protobuf::Timestamp
  sig { returns(Time) }
  def to_time; end

  class << self
    sig { params(time: Time).returns(Google::Protobuf::Timestamp) }
    def from_time(time); end
  end
end

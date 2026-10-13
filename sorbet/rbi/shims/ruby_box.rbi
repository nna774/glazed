# typed: strict

# SPDX-License-Identifier: Apache-2.0

# Ruby::Box is new in Ruby 4.0 and missing from Sorbet's core RBIs.

module Ruby
  class Box < Module
    has_attached_class!(:out)

    sig { returns(T::Boolean) }
    def self.enabled?; end

    sig { params(feature: String).returns(T::Boolean) }
    def require(feature); end
  end
end

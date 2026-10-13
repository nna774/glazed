# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

module Glazed
  module Storages
    module Base
      private def write(kind, key, content, content_type: 'text/plain')
        raise NotImplementedError
      end

      private def read(kind, key)
        raise NotImplementedError
      end

      private def read_pointer(pointer)
        raise NotImplementedError
      end

      private def delete(kind, key)
        raise NotImplementedError
      end

      private def delete_pointer(pointer)
        raise NotImplementedError
      end
    end
  end
end

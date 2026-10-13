# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/storages'

module Glazed
  Pointer = Data.define(:storage, :spec) do
    def as_json
      {
        storage: storage.name,
        spec: spec,
      }
    end

    def self.from_json(json)
      new(
        storage: Glazed::Storages.find(json.fetch('storage')),
        spec: json.fetch('spec'),
      )
    end
  end
end

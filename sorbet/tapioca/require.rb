# typed: true
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'aws-sdk-s3'
require 'aws-sdk-ssm'
require 'aws-sdk-states'
require 'dry/cli'
require 'google/protobuf'
require 'google/protobuf/descriptor_pb'
require 'google/protobuf/well_known_types'
require 'google/protobuf/wrappers_pb'
require 'httpx'
require 'net/ssh'
require 'net/telnet'
require 'protovalidate'
require 'sqlite3'

# typed: strict

# SPDX-License-Identifier: Apache-2.0

# aws-sdk-ssm defines response types as Struct.new(...) members, which tapioca
# does not see.

class Aws::SSM::Types::GetParameterResult
  sig { returns(T.nilable(Aws::SSM::Types::Parameter)) }
  def parameter; end
end

class Aws::SSM::Types::Parameter
  sig { returns(T.nilable(String)) }
  def value; end
end

# aws-sdk-ssm creates error classes for response codes on first reference.

class Aws::SSM::Errors::ParameterNotFound < Aws::SSM::Errors::ServiceError; end
class Aws::SSM::Errors::ParameterVersionNotFound < Aws::SSM::Errors::ServiceError; end

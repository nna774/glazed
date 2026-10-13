# typed: strict

# SPDX-License-Identifier: Apache-2.0

# net/ssh/proxy/command is not loaded by net/ssh, so tapioca leaves it out.

module Net::SSH::Proxy
end

class Net::SSH::Proxy::Command
  sig { params(command_line_template: String).void }
  def initialize(command_line_template); end
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require_relative "lib/glazed/version"

Gem::Specification.new do |spec|
  spec.name = "glazed"
  spec.version = Glazed::VERSION
  spec.authors = ["Sorah Fukumori"]
  spec.email = ["her@sorah.jp"]

  spec.summary = "Network device configuration scraper, a modern successor of oxidized"
  spec.homepage = "https://github.com/sorah/glazed"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sorah/glazed/tree/main/glazed"
  spec.metadata["changelog_uri"] = "https://github.com/sorah/glazed/blob/main/glazed/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "google-protobuf"
  spec.add_dependency "httpx"
  spec.add_dependency "net-ssh"
  spec.add_dependency "net-telnet"
end

# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require_relative "lib/glazed/aws/version"

Gem::Specification.new do |spec|
  spec.name = "glazed-aws"
  spec.version = Glazed::Aws::VERSION
  spec.authors = ["Sorah Fukumori"]
  spec.email = ["her@sorah.jp"]

  spec.summary = "AWS integrations for glazed, such as S3 storage"
  spec.homepage = "https://github.com/sorah/glazed"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sorah/glazed/tree/main/glazed-aws"
  spec.metadata["changelog_uri"] = "https://github.com/sorah/glazed/blob/main/glazed-aws/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ lambda/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "glazed", "~> 0.2.0"
  spec.add_dependency "aws-sdk-s3"
  spec.add_dependency "aws-sdk-ssm"
  spec.add_dependency "aws-sdk-states"
  spec.add_dependency "dry-cli"
end

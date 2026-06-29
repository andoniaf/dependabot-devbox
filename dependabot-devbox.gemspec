# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name        = "dependabot-devbox"
  spec.version     = "0.1.0"
  spec.summary     = "Dependabot support for Devbox"
  spec.description = "Automatically update Devbox (devbox.json) package versions via Dependabot. " \
                     "Standalone gem for use before official dependabot-core support lands."

  spec.author   = "Andoni A."
  spec.email    = ["andonialonsof@gmail.com"]
  spec.homepage = "https://github.com/andoniaf/dependabot-devbox"
  spec.license  = "MIT"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/andoniaf/dependabot-devbox/issues",
    "changelog_uri" => "https://github.com/andoniaf/dependabot-devbox/releases",
    "source_code_uri" => "https://github.com/andoniaf/dependabot-devbox",
    "rubygems_mfa_required" => "true"
  }

  spec.required_ruby_version = ">= 3.3.0"
  spec.require_path = "lib"
  spec.files        = Dir["lib/**/*"]
  spec.bindir       = "exe"
  spec.executables  = ["dependabot-devbox-update"]

  spec.add_dependency "dependabot-common", "~> 0.383"
end

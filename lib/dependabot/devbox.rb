# typed: strong
# frozen_string_literal: true

require "dependabot/devbox/file_fetcher"
require "dependabot/devbox/file_parser"
require "dependabot/devbox/update_checker"
require "dependabot/devbox/file_updater"
require "dependabot/devbox/metadata_finder"
require "dependabot/devbox/package/package_details_fetcher"
require "dependabot/devbox/helpers"
require "dependabot/devbox/version"
require "dependabot/devbox/requirement"

require "dependabot/pull_request_creator/labeler"
Dependabot::PullRequestCreator::Labeler
  .register_label_details("devbox", name: "devbox", colour: "5c4ee5")

require "dependabot/dependency"
Dependabot::Dependency.register_production_check("devbox", ->(_) { true })

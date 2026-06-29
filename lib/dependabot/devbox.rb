# typed: strong
# frozen_string_literal: true

require "dependabot/utils"
require "dependabot/config/file"

# The published dependabot-common gem predates the devbox entry being added
# to PACKAGE_MANAGER_LOOKUP. Patch validate_package_manager! to allow "devbox"
# until the upstream PR merges and a new gem version is published.
module Dependabot
  module Utils
    class << self
      private

      def validate_package_manager!(package_manager)
        return if package_manager == "devbox"
        return if Config::File::REVERSE_PACKAGE_MANAGER_LOOKUP.key?(package_manager)
        return if %w[dummy silent].include?(package_manager)

        raise "Unsupported package_manager #{package_manager}"
      end
    end
  end
end

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

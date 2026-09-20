# typed: strong
# frozen_string_literal: true

require "dependabot/utils"
require "dependabot/config/file"

module Dependabot
  module Devbox
    # The published dependabot-common gem predates the devbox entry being
    # added to PACKAGE_MANAGER_LOOKUP. Until upstream ships it, allow "devbox"
    # through the private validation hook. The patch is prepended (so the
    # upstream implementation still runs for every other ecosystem), applied
    # only while the hook exists under its current name, and retires itself
    # once upstream knows about devbox.
    module PackageManagerPatch
      private

      def validate_package_manager!(package_manager)
        return if package_manager == "devbox"

        super
      end
    end

    if !Dependabot::Config::File::REVERSE_PACKAGE_MANAGER_LOOKUP.key?("devbox") &&
       Dependabot::Utils.singleton_class.private_method_defined?(:validate_package_manager!)
      Dependabot::Utils.singleton_class.prepend(PackageManagerPatch)
    end
  end
end

require "dependabot/devbox/constants"
require "dependabot/devbox/nixhub"
require "dependabot/devbox/file_fetcher"
require "dependabot/devbox/file_parser"
require "dependabot/devbox/update_checker"
require "dependabot/devbox/file_updater"
require "dependabot/devbox/metadata_finder"
require "dependabot/devbox/package/package_details_fetcher"
require "dependabot/devbox/helpers"
require "dependabot/devbox/version"
require "dependabot/devbox/requirement"
require "dependabot/devbox/update_runner"

require "dependabot/pull_request_creator/labeler"
Dependabot::PullRequestCreator::Labeler
  .register_label_details("devbox", name: "devbox", colour: "5c4ee5")

require "dependabot/dependency"
Dependabot::Dependency.register_production_check("devbox", ->(_) { true })

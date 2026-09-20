# typed: strict
# frozen_string_literal: true

require "time"
require "sorbet-runtime"
require "dependabot/package/package_release"
require "dependabot/devbox/nixhub"
require "dependabot/devbox/version"

module Dependabot
  module Devbox
    module Package
      class PackageDetailsFetcher
        extend T::Sig

        sig { params(dependency: Dependabot::Dependency).void }
        def initialize(dependency:)
          @dependency = dependency
        end

        sig { returns(T::Array[Dependabot::Package::PackageRelease]) }
        def available_versions
          Nixhub.versions(Nixhub.package(dependency.name)).filter_map do |version_data|
            version_str = version_data["version"]
            next unless version_str.is_a?(String) && Devbox::Version.correct?(version_str)

            Dependabot::Package::PackageRelease.new(
              version: Devbox::Version.new(version_str),
              released_at: release_time(version_data)
            )
          end
        end

        private

        sig { returns(Dependabot::Dependency) }
        attr_reader :dependency

        # Approximates a version's release date with the earliest per-system
        # `last_updated` (Unix epoch seconds), falling back to the top-level
        # `last_updated`. `filter_by_cooldown` treats a nil result gracefully.
        sig { params(version_data: T::Hash[String, Object]).returns(T.nilable(Time)) }
        def release_time(version_data)
          timestamps = []

          systems = version_data["systems"]
          timestamps.concat(systems.values.filter_map { |s| s["last_updated"] if s.is_a?(Hash) }) if systems.is_a?(Hash)
          timestamps << version_data["last_updated"]

          epoch = timestamps.grep(Integer).min
          epoch ? Time.at(epoch).utc : nil
        end
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/dependency"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"
require "dependabot/package/release_cooldown_options"

module Dependabot
  module Devbox
    # Extracted from exe/dependabot-devbox-update so its per-dependency and
    # per-PR logic can be unit tested without loading the executable itself
    # (which RubyGems' bin stub runs via Kernel#load, under which the
    # conventional `$PROGRAM_NAME == __FILE__` require-guard never matches).
    module UpdateRunner
      extend T::Sig

      sig { params(days: Integer).returns(T.nilable(Dependabot::Package::ReleaseCooldownOptions)) }
      def self.build_cooldown(days)
        return nil unless days.positive?

        Dependabot::Package::ReleaseCooldownOptions.new(default_days: days)
      end

      # Classifies by comparing the major segment of the previous and new
      # version strings, so it works for both semver ("24.11.1" -> "26.4.0")
      # and nixpkgs' shorter version strings ("0.99.4" -> "1.0.4").
      sig { params(dependency: Dependabot::Dependency).returns(T::Boolean) }
      def self.major_bump?(dependency)
        previous = dependency.previous_version
        current = dependency.version
        return false unless previous && current

        previous.to_s.split(".").first != current.to_s.split(".").first
      end

      sig do
        params(dependencies: T::Array[Dependabot::Dependency])
          .returns([T::Array[Dependabot::Dependency], T::Array[Dependabot::Dependency]])
      end
      def self.partition_majors(dependencies)
        dependencies.partition { |dep| major_bump?(dep) }
      end

      sig do
        params(
          dependency: Dependabot::Dependency,
          files: T::Array[Dependabot::DependencyFile],
          credentials: T::Array[T.untyped],
          cooldown: T.nilable(Dependabot::Package::ReleaseCooldownOptions)
        ).returns(T.nilable(T::Array[Dependabot::Dependency]))
      end
      def self.check_dependency(dependency, files, credentials, cooldown)
        puts "Checking #{dependency.name} (#{dependency.version})..."

        checker = Dependabot::UpdateCheckers.for_package_manager("devbox").new(
          dependency: dependency,
          dependency_files: files,
          credentials: credentials,
          update_cooldown: cooldown
        )

        if checker.up_to_date?
          puts "  up to date"
          return nil
        end

        requirements_to_unlock = checker.requirements_unlocked_or_can_be? ? :own : :none

        begin
          checker.updated_dependencies(requirements_to_unlock: requirements_to_unlock)
        rescue Dependabot::AllVersionsIgnored
          puts "  all versions ignored"
          nil
        end
      end

      sig do
        params(
          source: T.untyped,
          commit: String,
          dependencies: T::Array[Dependabot::Dependency],
          files: T::Array[Dependabot::DependencyFile],
          credentials: T::Array[T.untyped],
          indent: String
        ).void
      end
      def self.open_pr(source, commit, dependencies, files, credentials, indent: "")
        updater = Dependabot::FileUpdaters.for_package_manager("devbox").new(
          dependencies: dependencies,
          dependency_files: files,
          credentials: credentials
        )

        updated_files = updater.updated_dependency_files

        pr_creator = Dependabot::PullRequestCreator.new(
          source: source,
          base_commit: commit,
          dependencies: dependencies,
          files: updated_files,
          credentials: credentials,
          label_language: true
        )

        pr = pr_creator.create
        if pr
          puts "#{indent}PR created: #{pr.html_url}"
        else
          puts "#{indent}PR already exists or no changes needed"
        end
      rescue Dependabot::PullRequestCreator::UnmergedPRExists => e
        puts "#{indent}Skipping: #{e.message} (closed but not merged — delete the branch to recreate)"
      rescue Dependabot::PullRequestCreator::BranchAlreadyExists => e
        puts "#{indent}Skipping: #{e.message} (stale branch with no open PR — delete it to retry)"
      end
    end
  end
end

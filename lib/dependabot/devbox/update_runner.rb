# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/credential"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/errors"
require "dependabot/logger"
require "dependabot/source"
require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"
require "dependabot/package/release_cooldown_options"
require "dependabot/devbox/constants"
require "dependabot/devbox/helpers"

module Dependabot
  module Devbox
    # The orchestration behind exe/dependabot-devbox-update: reads the
    # configuration from the environment, fetches and parses the devbox files,
    # checks every package and opens the pull requests. Lives here rather than
    # in the executable so it can be unit tested (RubyGems' bin stub runs the
    # executable via Kernel#load, under which the conventional
    # `$PROGRAM_NAME == __FILE__` require-guard never matches).
    module UpdateRunner
      extend T::Sig

      class ConfigurationError < Dependabot::DependabotError; end

      class Config < T::Struct
        extend T::Sig

        const :repo, String
        const :token, String
        const :directory, String, default: "/"
        const :branch, T.nilable(String), default: nil
        const :group_updates, T::Boolean, default: false
        const :cooldown_days, Integer, default: 0
        const :excluded_packages, T::Array[String], default: []

        # Every value is validated up front so a misconfigured workflow fails
        # with a clear message instead of a misleading error deep in the run
        # (an empty token, for instance, otherwise surfaces as "repo not found"
        # or as an authorization failure only once a PR is about to be opened).
        sig { params(env: T::Hash[String, T.nilable(String)]).returns(Config) }
        def self.from_env(env = ENV.to_h)
          new(
            repo: required(env, "GITHUB_REPOSITORY"),
            token: present(env["GITHUB_ACCESS_TOKEN"]) || required(env, "GITHUB_TOKEN"),
            directory: present(env["DIRECTORY_PATH"]) || "/",
            branch: present(env["BASE_BRANCH"]),
            group_updates: env["GROUP_UPDATES"].to_s.strip.downcase == "true",
            cooldown_days: cooldown_days(env["COOLDOWN_DAYS"]),
            excluded_packages: Helpers.parse_exclude_list(env["EXCLUDE_PACKAGES"])
          )
        end

        sig { params(value: T.nilable(String)).returns(T.nilable(String)) }
        def self.present(value)
          stripped = value.to_s.strip
          stripped.empty? ? nil : stripped
        end

        sig { params(env: T::Hash[String, T.nilable(String)], name: String).returns(String) }
        def self.required(env, name)
          present(env[name]) || raise(ConfigurationError, "#{name} must be set and non-empty")
        end

        sig { params(value: T.nilable(String)).returns(Integer) }
        def self.cooldown_days(value)
          return 0 unless present(value)

          days = Integer(value.to_s.strip, 10, exception: false)
          if days.nil? || days.negative?
            raise ConfigurationError, "COOLDOWN_DAYS must be a non-negative integer, got #{value.inspect}"
          end

          days
        end

        sig { returns(T.nilable(Dependabot::Package::ReleaseCooldownOptions)) }
        def cooldown
          UpdateRunner.build_cooldown(cooldown_days)
        end

        sig { returns(T::Array[Dependabot::Credential]) }
        def credentials
          [Dependabot::Credential.new(
            {
              "type" => "git_source",
              "host" => "github.com",
              "username" => "x-access-token",
              "password" => token
            }
          )]
        end

        sig { returns(Dependabot::Source) }
        def source
          Dependabot::Source.new(provider: "github", repo: repo, directory: directory, branch: branch)
        end
      end

      # Runs a full update for the given configuration and returns the exit
      # status: non-zero if any step failed.
      sig { params(config: Config).returns(Integer) }
      def self.run(config)
        Run.new(config).call
      end

      # One update run. A failure while checking or updating one package is
      # logged and does not stop the remaining packages; the exit status is
      # non-zero if anything failed, so the workflow still reports the problem.
      class Run
        extend T::Sig

        sig { params(config: Config).void }
        def initialize(config)
          @config = config
          @source = T.let(config.source, Dependabot::Source)
          @credentials = T.let(config.credentials, T::Array[Dependabot::Credential])
          @failures = T.let([], T::Array[String])
          @files = T.let([], T::Array[Dependabot::DependencyFile])
          @commit = T.let("", String)
        end

        sig { returns(Integer) }
        def call
          raise ConfigurationError, "devbox CLI not found on PATH" unless Helpers.devbox_available?

          dependencies = fetch_dependencies
          updates = dependencies.filter_map do |dep|
            capture("check #{dep.name}") do
              UpdateRunner.check_dependency(dependency: dep, files: @files, credentials: @credentials,
                                            cooldown: @config.cooldown)
            end
          end

          if updates.empty?
            log("All packages up to date.")
          elsif @config.group_updates
            open_grouped_prs(updates.flatten)
          else
            updates.each { |deps| open_pr(deps) }
          end

          log("Done.")
          return 0 if @failures.empty?

          log("#{@failures.length} step(s) failed: #{@failures.join('; ')}")
          1
        end

        private

        sig { returns(T::Array[Dependabot::Dependency]) }
        def fetch_dependencies
          location = @config.directory == "/" ? @config.repo : "#{@config.repo} (#{@config.directory})"
          log("Fetching devbox files from #{location}")

          fetcher = Dependabot::FileFetchers.for_package_manager("devbox")
                                            .new(source: @source, credentials: @credentials)
          @files = fetcher.files
          @commit = fetcher.commit

          parser = Dependabot::FileParsers.for_package_manager("devbox")
                                          .new(dependency_files: @files, source: @source, credentials: @credentials)
          dependencies = parser.parse
          log("Found #{dependencies.length} devbox package(s)")

          dependencies.reject do |dep|
            excluded = @config.excluded_packages.include?(dep.name)
            log("Excluding #{dep.name} (matched exclude-packages)") if excluded
            excluded
          end
        end

        sig { params(updates: T::Array[Dependabot::Dependency]).void }
        def open_grouped_prs(updates)
          majors, rest = UpdateRunner.partition_majors(updates)

          open_pr(rest) unless rest.empty?
          majors.each do |dep|
            log("Opening individual PR for major bump: #{dep.name}")
            open_pr([dep])
          end
        end

        sig { params(dependencies: T::Array[Dependabot::Dependency]).void }
        def open_pr(dependencies)
          capture("open PR for #{dependencies.map(&:name).join(', ')}") do
            UpdateRunner.open_pr(source: @source, commit: @commit, dependencies: dependencies, files: @files,
                                 credentials: @credentials)
          end
        end

        sig { type_parameters(:T).params(step: String).returns(T.nilable(T.type_parameter(:T))) }
        def capture(step)
          yield
        rescue StandardError => e
          Dependabot.logger.error("  Failed to #{step}: #{e.class}: #{e.message}")
          @failures << step
          nil
        end

        sig { params(message: String).void }
        def log(message)
          Dependabot.logger.info(message)
        end
      end

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

      # The updated dependencies for one package, or nil when there is nothing
      # to do. A package whose lockfile entry is missing (so its current
      # version is unknown) yields no updated dependencies and is skipped
      # rather than handed to the file updater with nothing to update.
      sig do
        params(
          dependency: Dependabot::Dependency,
          files: T::Array[Dependabot::DependencyFile],
          credentials: T::Array[Dependabot::Credential],
          cooldown: T.nilable(Dependabot::Package::ReleaseCooldownOptions)
        ).returns(T.nilable(T::Array[Dependabot::Dependency]))
      end
      def self.check_dependency(dependency:, files:, credentials:, cooldown: nil)
        log("Checking #{dependency.name} (#{dependency.version || 'unresolved'})...")

        checker = Dependabot::UpdateCheckers.for_package_manager("devbox").new(
          dependency: dependency,
          dependency_files: files,
          credentials: credentials,
          update_cooldown: cooldown
        )

        if checker.up_to_date?
          log("  up to date")
          return nil
        end

        requirements_to_unlock = checker.requirements_unlocked_or_can_be? ? :own : :none
        updated = checker.updated_dependencies(requirements_to_unlock: requirements_to_unlock)
        if updated.empty?
          log("  no resolvable update (is #{dependency.name} present in #{LOCKFILE_FILENAME}?)")
          return nil
        end

        updated
      rescue Dependabot::AllVersionsIgnored
        log("  all versions ignored")
        nil
      end

      sig do
        params(
          source: Dependabot::Source,
          commit: String,
          dependencies: T::Array[Dependabot::Dependency],
          files: T::Array[Dependabot::DependencyFile],
          credentials: T::Array[Dependabot::Credential]
        ).void
      end
      def self.open_pr(source:, commit:, dependencies:, files:, credentials:)
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
          log("  PR created: #{pr.html_url}")
        else
          log("  PR already exists or no changes needed")
        end
      rescue Dependabot::PullRequestCreator::UnmergedPRExists => e
        log("  Skipping: #{e.message} (closed but not merged — delete the branch to recreate)")
      rescue Dependabot::PullRequestCreator::BranchAlreadyExists => e
        log("  Skipping: #{e.message} (stale branch with no open PR — delete it to retry)")
      end

      sig { params(message: String).void }
      def self.log(message)
        Dependabot.logger.info(message)
      end
      private_class_method :log
    end
  end
end

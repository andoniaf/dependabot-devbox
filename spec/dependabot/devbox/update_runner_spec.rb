# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"
require "dependabot/devbox/update_runner"
require "dependabot/package/release_cooldown_options"

RSpec.describe Dependabot::Devbox::UpdateRunner do
  def dependency(version:, previous_version:, name: "python")
    Dependabot::Dependency.new(
      name: name,
      version: version,
      previous_version: previous_version,
      requirements: [{ requirement: version, file: "devbox.json", groups: [], source: { type: "nixhub" } }],
      previous_requirements: [{ requirement: previous_version, file: "devbox.json", groups: [],
                                source: { type: "nixhub" } }],
      package_manager: "devbox"
    )
  end

  let(:files) { [Dependabot::DependencyFile.new(name: "devbox.json", content: '{ "packages": [] }')] }
  let(:credentials) do
    [Dependabot::Credential.new(
      { "type" => "git_source", "host" => "github.com", "username" => "x-access-token", "password" => "token" }
    )]
  end
  let(:source) { Dependabot::Source.new(provider: "github", repo: "org/repo") }

  describe described_class::Config do
    let(:env) { { "GITHUB_REPOSITORY" => "org/repo", "GITHUB_ACCESS_TOKEN" => "ghp_x" } }

    it "reads the required values" do
      config = described_class.from_env(env)

      expect(config.repo).to eq("org/repo")
      expect(config.token).to eq("ghp_x")
    end

    it "applies defaults for the optional values" do
      config = described_class.from_env(env)

      expect(config.directory).to eq("/")
      expect(config.branch).to be_nil
      expect(config.group_updates).to be(false)
      expect(config.cooldown_days).to eq(0)
      expect(config.excluded_packages).to eq([])
    end

    it "reads every option" do
      config = described_class.from_env(
        env.merge(
          "DIRECTORY_PATH" => "/services/api",
          "BASE_BRANCH" => "develop",
          "GROUP_UPDATES" => "true",
          "COOLDOWN_DAYS" => "7",
          "EXCLUDE_PACKAGES" => "go, nodejs"
        )
      )

      expect(config.directory).to eq("/services/api")
      expect(config.branch).to eq("develop")
      expect(config.group_updates).to be(true)
      expect(config.cooldown_days).to eq(7)
      expect(config.excluded_packages).to eq(%w(go nodejs))
    end

    it "falls back to GITHUB_TOKEN when GITHUB_ACCESS_TOKEN is empty" do
      config = described_class.from_env(env.merge("GITHUB_ACCESS_TOKEN" => "", "GITHUB_TOKEN" => "ghs_y"))
      expect(config.token).to eq("ghs_y")
    end

    it "treats a blank base branch as unset" do
      config = described_class.from_env(env.merge("BASE_BRANCH" => "  "))
      expect(config.branch).to be_nil
    end

    it "fails fast when no token is provided" do
      expect { described_class.from_env(env.merge("GITHUB_ACCESS_TOKEN" => "")) }
        .to raise_error(Dependabot::Devbox::UpdateRunner::ConfigurationError, /GITHUB_TOKEN/)
    end

    it "fails fast when the repository is missing" do
      expect { described_class.from_env(env.merge("GITHUB_REPOSITORY" => nil)) }
        .to raise_error(Dependabot::Devbox::UpdateRunner::ConfigurationError, /GITHUB_REPOSITORY/)
    end

    it "rejects a non-numeric cooldown" do
      expect { described_class.from_env(env.merge("COOLDOWN_DAYS" => "abc")) }
        .to raise_error(Dependabot::Devbox::UpdateRunner::ConfigurationError, /COOLDOWN_DAYS/)
    end

    it "rejects a negative cooldown" do
      expect { described_class.from_env(env.merge("COOLDOWN_DAYS" => "-1")) }
        .to raise_error(Dependabot::Devbox::UpdateRunner::ConfigurationError, /COOLDOWN_DAYS/)
    end

    it "builds git credentials and a source from the configuration" do
      config = described_class.from_env(env.merge("DIRECTORY_PATH" => "/app", "BASE_BRANCH" => "main"))

      expect(config.credentials.map(&:to_h)).to eq(
        [{ "type" => "git_source", "host" => "github.com", "username" => "x-access-token", "password" => "ghp_x" }]
      )
      expect(config.source.repo).to eq("org/repo")
      expect(config.source.directory).to eq("/app")
      expect(config.source.branch).to eq("main")
    end
  end

  describe ".major_bump?" do
    it "is true when the major segment increases" do
      dep = dependency(version: "26.4.0", previous_version: "24.11.1")
      expect(described_class.major_bump?(dep)).to be(true)
    end

    it "is true for a 0.x -> 1.x jump" do
      dep = dependency(name: "terragrunt", version: "1.0.4", previous_version: "0.99.4")
      expect(described_class.major_bump?(dep)).to be(true)
    end

    it "is false when only the minor segment increases" do
      dep = dependency(name: "postgresql", version: "17.10", previous_version: "17.7")
      expect(described_class.major_bump?(dep)).to be(false)
    end

    it "is false when only the patch segment increases" do
      dep = dependency(version: "3.10.19", previous_version: "3.10.13")
      expect(described_class.major_bump?(dep)).to be(false)
    end

    it "is false when there is no previous version" do
      dep = dependency(version: "3.10.19", previous_version: nil)
      expect(described_class.major_bump?(dep)).to be(false)
    end
  end

  describe ".partition_majors" do
    it "splits major bumps from minor/patch bumps" do
      major = dependency(name: "nodejs", version: "26.4.0", previous_version: "24.11.1")
      minor = dependency(name: "postgresql", version: "17.10", previous_version: "17.7")
      patch = dependency(name: "goose", version: "3.10.19", previous_version: "3.10.13")

      majors, rest = described_class.partition_majors([major, minor, patch])

      expect(majors).to eq([major])
      expect(rest).to eq([minor, patch])
    end
  end

  describe ".build_cooldown" do
    it "returns nil when days is zero" do
      expect(described_class.build_cooldown(0)).to be_nil
    end

    it "builds a ReleaseCooldownOptions with the given default_days when positive" do
      cooldown = described_class.build_cooldown(7)

      expect(cooldown).to be_a(Dependabot::Package::ReleaseCooldownOptions)
      expect(cooldown.default_days).to eq(7)
    end
  end

  describe ".check_dependency" do
    let(:dep) { dependency(version: "3.10.19", previous_version: "3.10.13") }
    let(:cooldown) { Dependabot::Package::ReleaseCooldownOptions.new(default_days: 7) }
    let(:checker_class) { Dependabot::UpdateCheckers.for_package_manager("devbox") }

    def stub_checker(**attrs)
      checker = instance_double(Dependabot::Devbox::UpdateChecker, **attrs)
      allow(checker_class).to receive(:new).and_return(checker)
      checker
    end

    it "forwards the cooldown option to the update checker" do
      stub_checker(up_to_date?: true)

      described_class.check_dependency(dependency: dep, files: files, credentials: credentials, cooldown: cooldown)

      expect(checker_class).to have_received(:new).with(hash_including(update_cooldown: cooldown))
    end

    it "passes nil update_cooldown through unchanged" do
      stub_checker(up_to_date?: true)

      described_class.check_dependency(dependency: dep, files: files, credentials: credentials, cooldown: nil)

      expect(checker_class).to have_received(:new).with(hash_including(update_cooldown: nil))
    end

    it "returns the updated dependencies when an update is available" do
      updated = dependency(version: "3.10.20", previous_version: "3.10.19")
      stub_checker(up_to_date?: false, requirements_unlocked_or_can_be?: true, updated_dependencies: [updated])

      result = described_class.check_dependency(dependency: dep, files: files, credentials: credentials)

      expect(result).to eq([updated])
    end

    it "returns nil when the checker yields no updated dependencies" do
      # A package with no devbox.lock entry has no current version: the checker
      # reports it as not up to date but produces nothing to update.
      stub_checker(up_to_date?: false, requirements_unlocked_or_can_be?: false, updated_dependencies: [])

      result = described_class.check_dependency(dependency: dep, files: files, credentials: credentials)

      expect(result).to be_nil
    end

    it "returns nil when all versions are ignored" do
      checker = stub_checker(up_to_date?: false, requirements_unlocked_or_can_be?: true)
      allow(checker).to receive(:updated_dependencies).and_raise(Dependabot::AllVersionsIgnored)

      expect(described_class.check_dependency(dependency: dep, files: files, credentials: credentials)).to be_nil
    end
  end

  describe ".open_pr" do
    let(:dep) { dependency(version: "3.10.19", previous_version: "3.10.13") }
    let(:updater) { instance_double(Dependabot::Devbox::FileUpdater, updated_dependency_files: files) }
    let(:pr_creator) { instance_double(Dependabot::PullRequestCreator) }

    before do
      allow(Dependabot::FileUpdaters.for_package_manager("devbox")).to receive(:new).and_return(updater)
      allow(Dependabot::PullRequestCreator).to receive(:new).and_return(pr_creator)
    end

    def open_pr
      described_class.open_pr(source: source, commit: "sha", dependencies: [dep], files: files,
                              credentials: credentials)
    end

    it "does not raise when the branch already exists with no open PR" do
      allow(pr_creator).to receive(:create)
        .and_raise(Dependabot::PullRequestCreator::BranchAlreadyExists, "branch already exists")

      expect { open_pr }.not_to raise_error
    end

    it "does not raise when an unmerged PR already exists" do
      allow(pr_creator).to receive(:create)
        .and_raise(Dependabot::PullRequestCreator::UnmergedPRExists, "unmerged PR exists")

      expect { open_pr }.not_to raise_error
    end

    it "propagates unexpected failures so the caller can record them" do
      allow(pr_creator).to receive(:create).and_raise(Dependabot::DependencyFileNotResolvable, "boom")

      expect { open_pr }.to raise_error(Dependabot::DependencyFileNotResolvable)
    end
  end

  describe ".run" do
    let(:config) do
      described_class::Config.new(repo: "org/repo", token: "ghp_x", group_updates: group_updates,
                                  excluded_packages: excluded)
    end
    let(:group_updates) { false }
    let(:excluded) { [] }
    let(:parsed) { [nodejs, python] }

    def python = dependency(version: "3.10.13", previous_version: nil)
    def nodejs = dependency(name: "nodejs", version: "24.11.1", previous_version: nil)
    def goose = dependency(name: "goose", version: "3.10.13", previous_version: nil)
    def python_update = dependency(version: "3.10.19", previous_version: "3.10.13")
    def nodejs_update = dependency(name: "nodejs", version: "26.4.0", previous_version: "24.11.1")
    def goose_update = dependency(name: "goose", version: "3.10.19", previous_version: "3.10.13")

    before do
      fetcher = instance_double(Dependabot::Devbox::FileFetcher, files: files, commit: "sha")
      parser = instance_double(Dependabot::Devbox::FileParser, parse: parsed)
      allow(Dependabot::Devbox::Helpers).to receive(:devbox_available?).and_return(true)
      allow(Dependabot::FileFetchers.for_package_manager("devbox")).to receive(:new).and_return(fetcher)
      allow(Dependabot::FileParsers.for_package_manager("devbox")).to receive(:new).and_return(parser)
      allow(described_class).to receive(:check_dependency) do |dependency:, **|
        case dependency.name
        when "python" then [python_update]
        when "nodejs" then [nodejs_update]
        when "goose" then [goose_update]
        end
      end
      allow(described_class).to receive(:open_pr)
    end

    it "fails before touching the network when the devbox CLI is missing" do
      allow(Dependabot::Devbox::Helpers).to receive(:devbox_available?).and_return(false)

      expect { described_class.run(config) }
        .to raise_error(Dependabot::Devbox::UpdateRunner::ConfigurationError, /devbox CLI/)
      expect(Dependabot::FileFetchers.for_package_manager("devbox")).not_to have_received(:new)
    end

    it "opens one PR per updated package and exits zero" do
      expect(described_class.run(config)).to eq(0)

      expect(described_class).to have_received(:open_pr).with(hash_including(dependencies: [nodejs_update]))
      expect(described_class).to have_received(:open_pr).with(hash_including(dependencies: [python_update]))
    end

    it "keeps going when one package fails and exits non-zero" do
      allow(described_class).to receive(:open_pr).with(hash_including(dependencies: [nodejs_update]))
                                                 .and_raise(Dependabot::DependencyFileNotResolvable, "boom")

      expect(described_class.run(config)).to eq(1)

      expect(described_class).to have_received(:open_pr).with(hash_including(dependencies: [python_update]))
    end

    it "keeps going when checking one package fails" do
      allow(described_class).to receive(:check_dependency).with(hash_including(dependency: nodejs))
                                                          .and_raise(Excon::Error::Timeout, "timeout")
      allow(described_class).to receive(:check_dependency).with(hash_including(dependency: python))
                                                          .and_return([python_update])

      expect(described_class.run(config)).to eq(1)

      expect(described_class).to have_received(:open_pr).with(hash_including(dependencies: [python_update]))
    end

    it "skips packages that are up to date" do
      allow(described_class).to receive(:check_dependency).and_return(nil)

      expect(described_class.run(config)).to eq(0)
      expect(described_class).not_to have_received(:open_pr)
    end

    context "with excluded packages" do
      let(:excluded) { ["nodejs"] }

      it "does not check or update them" do
        described_class.run(config)

        expect(described_class).not_to have_received(:check_dependency).with(hash_including(dependency: nodejs))
        expect(described_class).not_to have_received(:open_pr).with(hash_including(dependencies: [nodejs_update]))
      end
    end

    context "with grouped updates" do
      let(:group_updates) { true }
      let(:parsed) { [goose, nodejs, python] }

      it "bundles minor/patch bumps and opens majors individually" do
        expect(described_class.run(config)).to eq(0)

        expect(described_class).to have_received(:open_pr)
          .with(hash_including(dependencies: [goose_update, python_update]))
        expect(described_class).to have_received(:open_pr).with(hash_including(dependencies: [nodejs_update]))
      end
    end
  end
end

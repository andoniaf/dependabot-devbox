# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
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
    let(:files) { [Dependabot::DependencyFile.new(name: "devbox.json", content: '{ "packages": [] }')] }
    let(:credentials) { [] }
    let(:cooldown) { Dependabot::Package::ReleaseCooldownOptions.new(default_days: 7) }

    it "forwards the cooldown option to the update checker" do
      checker = instance_double(Dependabot::Devbox::UpdateChecker, up_to_date?: true)
      allow(Dependabot::UpdateCheckers.for_package_manager("devbox")).to receive(:new).and_return(checker)

      described_class.check_dependency(dep, files, credentials, cooldown)

      expect(Dependabot::UpdateCheckers.for_package_manager("devbox"))
        .to have_received(:new).with(hash_including(update_cooldown: cooldown))
    end

    it "passes nil update_cooldown through unchanged" do
      checker = instance_double(Dependabot::Devbox::UpdateChecker, up_to_date?: true)
      allow(Dependabot::UpdateCheckers.for_package_manager("devbox")).to receive(:new).and_return(checker)

      described_class.check_dependency(dep, files, credentials, nil)

      expect(Dependabot::UpdateCheckers.for_package_manager("devbox"))
        .to have_received(:new).with(hash_including(update_cooldown: nil))
    end
  end

  describe ".open_pr" do
    let(:dep) { dependency(version: "3.10.19", previous_version: "3.10.13") }
    let(:files) { [Dependabot::DependencyFile.new(name: "devbox.json", content: '{ "packages": [] }')] }
    let(:credentials) { [] }
    let(:source) { Dependabot::Source.new(provider: "github", repo: "org/repo") }
    let(:updater) { instance_double(Dependabot::Devbox::FileUpdater, updated_dependency_files: files) }

    before do
      allow(Dependabot::FileUpdaters.for_package_manager("devbox")).to receive(:new).and_return(updater)
    end

    it "does not raise when the branch already exists with no open PR" do
      pr_creator = instance_double(Dependabot::PullRequestCreator)
      allow(Dependabot::PullRequestCreator).to receive(:new).and_return(pr_creator)
      allow(pr_creator).to receive(:create)
        .and_raise(Dependabot::PullRequestCreator::BranchAlreadyExists, "branch already exists")

      expect { described_class.open_pr(source, "sha", [dep], files, credentials) }.not_to raise_error
    end

    it "does not raise when an unmerged PR already exists" do
      pr_creator = instance_double(Dependabot::PullRequestCreator)
      allow(Dependabot::PullRequestCreator).to receive(:new).and_return(pr_creator)
      allow(pr_creator).to receive(:create)
        .and_raise(Dependabot::PullRequestCreator::UnmergedPRExists, "unmerged PR exists")

      expect { described_class.open_pr(source, "sha", [dep], files, credentials) }.not_to raise_error
    end
  end
end

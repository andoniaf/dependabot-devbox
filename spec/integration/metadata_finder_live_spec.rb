# typed: false
# frozen_string_literal: true

# Live integration test for MetadataFinder source resolution.
#
# Unlike the unit specs, these hit the network for real: the manifest of the
# public test repo (github.com/andoniaf/test-public), the Nixhub search API, and
# raw nixpkgs derivations. They are tagged `:integration` and excluded from the
# default run. Execute explicitly with:
#
#   bundle exec rspec --tag integration
#
require "spec_helper"
require "net/http"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/devbox/file_parser"
require "dependabot/devbox/metadata_finder"

RSpec.describe Dependabot::Devbox::MetadataFinder, :integration do
  let(:credentials) do
    [Dependabot::Credential.new(
      { "type" => "git_source", "host" => "github.com", "username" => "x-access-token", "password" => "" }
    )]
  end
  let(:source) { Dependabot::Source.new(provider: "github", repo: "andoniaf/test-public") }

  # Unhook WebMock's HTTP adapters so these examples reach the real network.
  # `webmock/rspec` re-arms net-connect blocking in its own before hook, so a
  # full disable/enable around each example is the reliable toggle.
  before { WebMock.disable! }
  after { WebMock.enable! }

  def finder_for(name, version)
    dependency = Dependabot::Dependency.new(
      name: name,
      version: version,
      requirements: [{ requirement: "latest", file: "devbox.json", groups: [], source: { type: "nixhub" } }],
      package_manager: "devbox"
    )
    Dependabot::Devbox::MetadataFinder.new(dependency: dependency, credentials: credentials)
  end

  it "parses the real test-public devbox.json and resolves its packages" do
    raw = Net::HTTP.get(URI("https://raw.githubusercontent.com/andoniaf/test-public/main/devbox.json"))
    manifest = Dependabot::DependencyFile.new(name: "devbox.json", content: raw)

    parser = Dependabot::Devbox::FileParser.new(
      dependency_files: [manifest], source: source, credentials: credentials
    )
    names = parser.parse.map(&:name)

    expect(names).to include("ripgrep", "jq")

    # ripgrep's Nixhub homepage is a GitHub URL, so the existing homepage path
    # resolves it.
    expect(finder_for("ripgrep", "13.0.0").source_url).to eq("https://github.com/BurntSushi/ripgrep")

    # jq's homepage is a GitHub Pages docs site and its derivation uses fetchurl
    # (not fetchFromGitHub), so it degrades gracefully to no source — proving the
    # fallback never regresses the previous behaviour.
    expect { finder_for("jq", "1.6").source_url }.not_to raise_error
  end

  # The feature under test: a package whose homepage is a docs site but whose
  # nixpkgs by-name derivation uses fetchFromGitHub now resolves to the real repo.
  it "resolves a docs-homepage package via nixpkgs by-name fetchFromGitHub" do
    expect(finder_for("temporal-cli", "1.8.2").source_url).to eq("https://github.com/temporalio/cli")
  end
end

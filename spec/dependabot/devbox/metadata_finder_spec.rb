# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/metadata_finders"
require "dependabot/devbox/metadata_finder"

RSpec.describe Dependabot::Devbox::MetadataFinder do
  let(:finder) { described_class.new(dependency: dependency, credentials: credentials) }
  let(:credentials) do
    [Dependabot::Credential.new(
      {
        "type" => "git_source",
        "host" => "github.com",
        "username" => "x-access-token",
        "password" => "token"
      }
    )]
  end
  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: "14.1.0",
      requirements: [{
        requirement: "latest",
        file: "devbox.json",
        groups: [],
        source: { type: "nixhub" }
      }],
      package_manager: "devbox"
    )
  end
  let(:dependency_name) { "ripgrep" }
  let(:search_url) { "https://search.devbox.sh/v1/search?q=#{dependency_name}" }

  def stub_nixhub(homepage)
    stub_request(:get, search_url).to_return(
      status: 200,
      body: {
        packages: [
          { name: dependency_name, versions: [{ version: "14.1.0", homepage: homepage }] }
        ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  # Nixhub carries the nixpkgs attribute name per-system under `attr_paths`; the
  # by-name fallback derives the package.nix path from it.
  def stub_nixhub_with_attr(homepage:, attr:)
    stub_request(:get, search_url).to_return(
      status: 200,
      body: {
        packages: [
          {
            name: dependency_name,
            versions: [
              {
                version: "14.1.0",
                homepage: homepage,
                systems: {
                  "x86_64-linux" => { "attr_paths" => [attr] }
                }
              }
            ]
          }
        ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def by_name_url(attr)
    "https://raw.githubusercontent.com/NixOS/nixpkgs/master/pkgs/by-name/#{attr[0, 2]}/#{attr}/package.nix"
  end

  it "is registered for the devbox package manager" do
    expect(Dependabot::MetadataFinders.for_package_manager("devbox")).to eq(described_class)
  end

  context "when the homepage is a git host URL" do
    before { stub_nixhub("https://github.com/BurntSushi/ripgrep") }

    it "derives the source from the homepage" do
      expect(finder.source_url).to eq("https://github.com/BurntSushi/ripgrep")
    end
  end

  context "when the homepage is not a recognised git host" do
    before { stub_nixhub("https://www.python.org") }

    it "returns no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the package has no homepage" do
    before { stub_nixhub(nil) }

    it "returns no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the registry request times out" do
    before { stub_request(:get, search_url).to_timeout }

    it "returns no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the homepage is a docs site but nixpkgs resolves the repo" do
    let(:dependency_name) { "temporal-cli" }

    before do
      stub_nixhub_with_attr(homepage: "https://docs.temporal.io/cli", attr: "temporal-cli")
      stub_request(:get, by_name_url("temporal-cli")).to_return(
        status: 200,
        body: fixture("nixpkgs", "temporal-cli.package.nix")
      )
    end

    it "resolves the source from the by-name fetchFromGitHub block" do
      expect(finder.source_url).to eq("https://github.com/temporalio/cli")
    end
  end

  context "when the by-name derivation pins a bare rev" do
    let(:dependency_name) { "rev-pinned" }

    before do
      stub_nixhub_with_attr(homepage: "https://example.com/docs", attr: "rev-pinned")
      stub_request(:get, by_name_url("rev-pinned")).to_return(
        status: 200,
        body: fixture("nixpkgs", "rev-pinned.package.nix")
      )
    end

    it "still resolves the repo-level source" do
      expect(finder.source_url).to eq("https://github.com/example-org/example-repo")
    end
  end

  context "when the by-name package.nix does not exist" do
    let(:dependency_name) { "temporal-cli" }

    before do
      stub_nixhub_with_attr(homepage: "https://docs.temporal.io/cli", attr: "temporal-cli")
      stub_request(:get, by_name_url("temporal-cli")).to_return(status: 404, body: "Not Found")
    end

    it "falls back to no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the by-name package.nix is not a fetchFromGitHub source" do
    let(:dependency_name) { "temporal-cli" }

    before do
      stub_nixhub_with_attr(homepage: "https://docs.temporal.io/cli", attr: "temporal-cli")
      stub_request(:get, by_name_url("temporal-cli")).to_return(
        status: 200,
        body: <<~NIX
          { fetchurl }:
          stdenv.mkDerivation {
            src = fetchurl {
              url = "https://example.com/temporal-cli-1.8.2.tar.gz";
            };
          }
        NIX
      )
    end

    it "falls back to no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the attribute name has an uppercase first letter" do
    let(:dependency_name) { "MyPkg" }

    before do
      stub_nixhub_with_attr(homepage: "https://example.com/docs", attr: "MyPkg")
      # nixpkgs shards by the lowercased first two characters of the attr.
      stub_request(:get, "https://raw.githubusercontent.com/NixOS/nixpkgs/master/pkgs/by-name/my/MyPkg/package.nix")
        .to_return(status: 200, body: fixture("nixpkgs", "rev-pinned.package.nix"))
    end

    it "shards the by-name path using the lowercased prefix" do
      expect(finder.source_url).to eq("https://github.com/example-org/example-repo")
    end
  end

  context "when the attribute name contains path-traversal characters" do
    let(:dependency_name) { "evil" }

    before { stub_nixhub_with_attr(homepage: "https://example.com/docs", attr: "../../../etc/passwd") }

    it "rejects the attribute without fetching any derivation" do
      expect(finder.source_url).to be_nil
      expect(a_request(:get, /raw\.githubusercontent\.com/)).not_to have_been_made
    end
  end

  context "when the homepage is a git host it is preferred over the by-name lookup" do
    let(:dependency_name) { "temporal-cli" }

    before { stub_nixhub_with_attr(homepage: "https://github.com/temporalio/cli", attr: "temporal-cli") }

    it "does not fetch the by-name derivation" do
      expect(finder.source_url).to eq("https://github.com/temporalio/cli")
      expect(a_request(:get, by_name_url("temporal-cli"))).not_to have_been_made
    end
  end
end

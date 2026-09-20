# typed: false
# frozen_string_literal: true

require "spec_helper"
require "cgi"
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
      version: dependency_version,
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
  let(:dependency_version) { "14.1.0" }
  let(:search_url) { "https://search.devbox.sh/v1/search?q=#{CGI.escape(dependency_name)}" }
  let(:commit) { "c27cdad491a991b11ed731760aa2ef8db0cb0410" }

  def nixhub_version(version:, homepage:, attr: nil, commit: nil)
    entry = { version: version, homepage: homepage }
    entry[:commit_hash] = commit if commit
    entry[:systems] = { "x86_64-linux" => { "attr_paths" => [attr], "commit_hash" => commit } } if attr
    entry
  end

  def stub_nixhub(*versions)
    stub_request(:get, search_url).to_return(
      status: 200,
      body: { packages: [{ name: dependency_name, versions: versions }] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def by_name_url(attr, commit: self.commit)
    "https://raw.githubusercontent.com/NixOS/nixpkgs/#{commit}/pkgs/by-name/#{attr[0, 2].downcase}/#{attr}/package.nix"
  end

  def stub_package_nix(attr, body:, commit: self.commit)
    stub_request(:get, by_name_url(attr, commit: commit)).to_return(status: 200, body: body)
  end

  it "is registered for the devbox package manager" do
    expect(Dependabot::MetadataFinders.for_package_manager("devbox")).to eq(described_class)
  end

  context "when the homepage is a git host URL" do
    before { stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://github.com/BurntSushi/ripgrep")) }

    it "derives the source from the homepage" do
      expect(finder.source_url).to eq("https://github.com/BurntSushi/ripgrep")
    end
  end

  context "when the homepage is not a git host and Nixhub carries no nixpkgs metadata" do
    before { stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://www.python.org")) }

    it "returns no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the package has no homepage" do
    before { stub_nixhub(nixhub_version(version: "14.1.0", homepage: nil)) }

    it "returns no source" do
      expect(finder.source_url).to be_nil
    end

    it "memoises the miss instead of querying Nixhub again" do
      finder.source_url
      finder.source_url

      expect(a_request(:get, search_url)).to have_been_made.once
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
    let(:dependency_version) { "1.8.2" }

    before do
      stub_nixhub(nixhub_version(version: "1.8.2", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli",
                                 commit: commit))
      stub_package_nix("temporal-cli", body: fixture("nixpkgs", "temporal-cli.package.nix"))
    end

    it "resolves the source from the src = fetchFromGitHub block at the pinned nixpkgs commit" do
      expect(finder.source_url).to eq("https://github.com/temporalio/cli")
      expect(a_request(:get, by_name_url("temporal-cli"))).to have_been_made.once
    end
  end

  context "when several versions are listed" do
    let(:dependency_name) { "temporal-cli" }
    let(:dependency_version) { "1.8.2" }
    let(:older_commit) { "0" * 40 }

    before do
      stub_nixhub(
        nixhub_version(version: "1.8.1", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli",
                       commit: older_commit),
        nixhub_version(version: "1.8.2", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli",
                       commit: commit)
      )
      stub_package_nix("temporal-cli", body: fixture("nixpkgs", "temporal-cli.package.nix"))
    end

    it "inspects the derivation of the version being bumped" do
      expect(finder.source_url).to eq("https://github.com/temporalio/cli")
      expect(a_request(:get, by_name_url("temporal-cli", commit: older_commit))).not_to have_been_made
    end
  end

  context "when the by-name derivation pins a bare rev" do
    let(:dependency_name) { "rev-pinned" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://example.com/docs", attr: "rev-pinned",
                                 commit: commit))
      stub_package_nix("rev-pinned", body: fixture("nixpkgs", "rev-pinned.package.nix"))
    end

    it "still resolves the repo-level source" do
      expect(finder.source_url).to eq("https://github.com/example-org/example-repo")
    end
  end

  context "when a helper fetchFromGitHub is declared before src" do
    let(:dependency_name) { "ollama" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://ollama.com", attr: "ollama", commit: commit))
      stub_package_nix("ollama", body: fixture("nixpkgs", "helper-first.package.nix"))
    end

    it "resolves the block bound to src, not the first block in the file" do
      expect(finder.source_url).to eq("https://github.com/ollama/ollama")
    end
  end

  context "when the src block is written on a single line" do
    let(:dependency_name) { "one-liner" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://example.com", attr: "one-liner",
                                 commit: commit))
      stub_package_nix("one-liner", body: <<~NIX)
        { fetchFromGitHub }:
        stdenv.mkDerivation { src = fetchFromGitHub { owner = "a-org"; repo = "b-repo"; rev = "abc"; hash = ""; }; }
      NIX
    end

    it "resolves the source" do
      expect(finder.source_url).to eq("https://github.com/a-org/b-repo")
    end
  end

  context "when the by-name package.nix does not exist" do
    let(:dependency_name) { "temporal-cli" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli",
                                 commit: commit))
      stub_request(:get, by_name_url("temporal-cli")).to_return(status: 404, body: "Not Found")
    end

    it "falls back to no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the by-name fetch fails at the transport level" do
    let(:dependency_name) { "temporal-cli" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli",
                                 commit: commit))
    end

    it "falls back to no source on a timeout" do
      stub_request(:get, by_name_url("temporal-cli")).to_timeout

      expect(finder.source_url).to be_nil
    end

    it "falls back to no source on a redirect loop" do
      stub_request(:get, by_name_url("temporal-cli")).to_raise(Excon::Error::TooManyRedirects)

      expect(finder.source_url).to be_nil
    end
  end

  context "when the by-name package.nix is not a fetchFromGitHub source" do
    let(:dependency_name) { "temporal-cli" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli",
                                 commit: commit))
      stub_package_nix("temporal-cli", body: <<~NIX)
        { fetchurl }:
        stdenv.mkDerivation {
          src = fetchurl {
            url = "https://example.com/temporal-cli-1.8.2.tar.gz";
          };
        }
      NIX
    end

    it "falls back to no source" do
      expect(finder.source_url).to be_nil
    end
  end

  context "when the derivation's owner or repo is not a plain GitHub name" do
    let(:dependency_name) { "hostile" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://example.com", attr: "hostile", commit: commit))
      stub_package_nix("hostile", body: <<~NIX)
        { fetchFromGitHub }:
        stdenv.mkDerivation {
          src = fetchFromGitHub { owner = "../evil"; repo = "ghe.internal:443"; rev = "abc"; hash = ""; };
        }
      NIX
    end

    it "builds no source and probes no host" do
      expect(finder.source_url).to be_nil
      expect(a_request(:get, /evil|ghe\.internal/)).not_to have_been_made
    end
  end

  context "when the attribute name has an uppercase first letter" do
    let(:dependency_name) { "MyPkg" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://example.com/docs", attr: "MyPkg",
                                 commit: commit))
      stub_request(:get, "https://raw.githubusercontent.com/NixOS/nixpkgs/#{commit}/pkgs/by-name/my/MyPkg/package.nix")
        .to_return(status: 200, body: fixture("nixpkgs", "rev-pinned.package.nix"))
    end

    it "shards the by-name path using the lowercased prefix" do
      expect(finder.source_url).to eq("https://github.com/example-org/example-repo")
    end
  end

  context "when the attribute name is a single character" do
    let(:dependency_name) { "R" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://www.r-project.org", attr: "R", commit: commit))
      stub_request(:get, "https://raw.githubusercontent.com/NixOS/nixpkgs/#{commit}/pkgs/by-name/r/R/package.nix")
        .to_return(status: 200, body: fixture("nixpkgs", "rev-pinned.package.nix"))
    end

    it "shards on that character" do
      expect(finder.source_url).to eq("https://github.com/example-org/example-repo")
    end
  end

  context "when the attribute belongs to a package set" do
    let(:dependency_name) { "numpy" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://numpy.org", attr: "python311Packages.numpy",
                                 commit: commit))
    end

    it "does not attempt a by-name lookup" do
      expect(finder.source_url).to be_nil
      expect(a_request(:get, /raw\.githubusercontent\.com/)).not_to have_been_made
    end
  end

  context "when the attribute name contains path-traversal characters" do
    let(:dependency_name) { "evil" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://example.com/docs",
                                 attr: "../../../etc/passwd", commit: commit))
    end

    it "rejects the attribute without fetching any derivation" do
      expect(finder.source_url).to be_nil
      expect(a_request(:get, /raw\.githubusercontent\.com/)).not_to have_been_made
    end
  end

  context "when the nixpkgs commit is missing or malformed" do
    let(:dependency_name) { "temporal-cli" }

    it "does not fetch without a commit" do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli"))

      expect(finder.source_url).to be_nil
      expect(a_request(:get, /raw\.githubusercontent\.com/)).not_to have_been_made
    end

    it "does not fetch with a commit that is not a full sha" do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://docs.temporal.io/cli", attr: "temporal-cli",
                                 commit: "master/../"))

      expect(finder.source_url).to be_nil
      expect(a_request(:get, /raw\.githubusercontent\.com/)).not_to have_been_made
    end
  end

  context "when the homepage is a git host it is preferred over the by-name lookup" do
    let(:dependency_name) { "temporal-cli" }

    before do
      stub_nixhub(nixhub_version(version: "14.1.0", homepage: "https://github.com/temporalio/cli",
                                 attr: "temporal-cli", commit: commit))
    end

    it "does not fetch the by-name derivation" do
      expect(finder.source_url).to eq("https://github.com/temporalio/cli")
      expect(a_request(:get, by_name_url("temporal-cli"))).not_to have_been_made
    end
  end

  context "with recorded Nixhub and nixpkgs responses", :vcr do
    let(:dependency_name) { "temporal-cli" }
    let(:dependency_version) { "1.8.2" }

    it "resolves temporal-cli end to end" do
      expect(finder.source_url).to eq("https://github.com/temporalio/cli")
    end
  end
end

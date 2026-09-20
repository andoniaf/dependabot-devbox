# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/devbox/nixhub"

RSpec.describe Dependabot::Devbox::Nixhub do
  let(:search_url) { "https://search.devbox.sh/v1/search?q=python" }

  describe ".package" do
    it "returns the exact-name package from a fuzzy search" do
      packages = [{ name: "python3", versions: [] }, { name: "python", versions: [{ version: "3.12" }] }]
      stub_request(:get, search_url).to_return(status: 200, body: { packages: packages }.to_json)

      expect(described_class.package("python")).to eq("name" => "python", "versions" => [{ "version" => "3.12" }])
    end

    it "escapes the package name in the query" do
      stub_request(:get, "https://search.devbox.sh/v1/search?q=c%2B%2B").to_return(status: 200, body: "{}")

      described_class.package("c++")

      expect(a_request(:get, "https://search.devbox.sh/v1/search?q=c%2B%2B")).to have_been_made
    end

    it "returns nil when the package is not in the response" do
      stub_request(:get, search_url).to_return(status: 200, body: { packages: [{ name: "python3" }] }.to_json)

      expect(described_class.package("python")).to be_nil
    end

    it "returns nil on a non-200 response" do
      stub_request(:get, search_url).to_return(status: 503, body: "")

      expect(described_class.package("python")).to be_nil
    end

    it "returns nil on malformed JSON" do
      stub_request(:get, search_url).to_return(status: 200, body: "not json")

      expect(described_class.package("python")).to be_nil
    end

    it "returns nil on a timeout" do
      stub_request(:get, search_url).to_timeout

      expect(described_class.package("python")).to be_nil
    end
  end

  describe ".versions" do
    it "returns only the hash entries of the versions list" do
      package = { "versions" => [{ "version" => "1" }, "junk", nil, { "version" => "2" }] }

      expect(described_class.versions(package)).to eq([{ "version" => "1" }, { "version" => "2" }])
    end

    it "returns an empty list for a missing package or malformed versions" do
      expect(described_class.versions(nil)).to eq([])
      expect(described_class.versions({ "versions" => "nope" })).to eq([])
    end
  end
end

# typed: strict
# frozen_string_literal: true

require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"
require "dependabot/registry_client"
require "dependabot/source"
require "dependabot/devbox/nixhub"

module Dependabot
  module Devbox
    class MetadataFinder < Dependabot::MetadataFinders::Base
      extend T::Sig

      NIXPKGS_RAW_URL = "https://raw.githubusercontent.com/NixOS/nixpkgs"

      # The opening of the `src = fetchFromGitHub { ... }` binding. Anchoring
      # on `src` skips helper fetches declared earlier in the file (for
      # example a vendored dependency bound in a `let`).
      SRC_FETCH_FROM_GITHUB = /\bsrc\s*=\s*fetchFromGitHub\s*\{/
      OWNER_ATTR = /\bowner\s*=\s*"([^"]*)"/
      REPO_ATTR = /\brepo\s*=\s*"([^"]*)"/

      # nixpkgs attribute names that can live under pkgs/by-name. Dotted
      # attributes (python311Packages.numpy) belong to package sets and never
      # have a by-name entry, so they are rejected before any request is made.
      VALID_ATTR = /\A[A-Za-z0-9][A-Za-z0-9_+-]*\z/
      VALID_GITHUB_NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
      NIXPKGS_COMMIT = /\A[0-9a-f]{40}\z/

      # The nixpkgs commit a version was built from and the attribute it was
      # built as, both taken from Nixhub's per-version metadata.
      class NixpkgsRelease < T::Struct
        const :commit, String
        const :attr, String
      end

      private

      # Base#source memoises only a non-nil result, so a package with no
      # resolvable source would otherwise be looked up again for every section
      # of the PR message. Memoise the outcome either way.
      sig { override.returns(T.nilable(Dependabot::Source)) }
      def look_up_source
        @source_lookup ||= T.let([resolve_source], T.nilable([T.nilable(Dependabot::Source)]))
        @source_lookup.first
      end

      # nixpkgs packages expose a `homepage` in the Nixhub search response. When
      # it points at a recognised git host (e.g. GitHub) that is the source.
      # Otherwise (e.g. a docs site) fall back to the derivation nixpkgs built
      # the version from.
      sig { returns(T.nilable(Dependabot::Source)) }
      def resolve_source
        package = Nixhub.package(dependency.name)
        return nil unless package

        source_from_homepage(package) || source_from_nixpkgs(package)
      end

      sig { params(package: T::Hash[String, Object]).returns(T.nilable(Dependabot::Source)) }
      def source_from_homepage(package)
        homepage = Nixhub.versions(package).filter_map { |v| v["homepage"] }.find do |value|
          value.is_a?(String) && !value.empty?
        end
        return nil unless homepage

        Source.from_url(homepage)
      end

      # Nixhub records the nixpkgs commit per version, so package.nix is fetched
      # at that pinned commit rather than from master, where the package may
      # since have moved, been renamed or been re-sourced. Limited to the
      # by-name layout and `fetchFromGitHub`; any miss yields no source.
      sig { params(package: T::Hash[String, Object]).returns(T.nilable(Dependabot::Source)) }
      def source_from_nixpkgs(package)
        release = nixpkgs_release(package)
        return nil unless release

        contents = fetch_package_nix(release)
        return nil unless contents

        owner, repo = parse_github_source(contents)
        return nil unless owner && repo

        Source.new(provider: "github", repo: "#{owner}/#{repo}")
      end

      # Prefers the version entry matching the dependency's version, so the
      # derivation inspected is the one that built the version being bumped.
      sig { params(package: T::Hash[String, Object]).returns(T.nilable(NixpkgsRelease)) }
      def nixpkgs_release(package)
        versions = Nixhub.versions(package)
        version = versions.find { |v| v["version"] == dependency.version } || versions.first
        return nil unless version

        systems = version["systems"]
        systems = systems.is_a?(Hash) ? systems.values.grep(Hash) : []

        commit = string_matching(NIXPKGS_COMMIT, version["commit_hash"], *systems.map { |s| s["commit_hash"] })
        attr = string_matching(VALID_ATTR, *systems.flat_map { |s| Array(s["attr_paths"]) })
        return nil unless commit && attr

        NixpkgsRelease.new(commit: commit, attr: attr)
      end

      sig { params(pattern: Regexp, candidates: T.untyped).returns(T.nilable(String)) }
      def string_matching(pattern, *candidates)
        candidates.find { |value| value.is_a?(String) && value.match?(pattern) }
      end

      # by-name shards on the lowercased first two characters of the attribute
      # (a one-character attribute shards on that character alone). This is a
      # best-effort enrichment, so it is not retried.
      sig { params(release: NixpkgsRelease).returns(T.nilable(String)) }
      def fetch_package_nix(release)
        shard = T.must(release.attr[0, 2]).downcase
        response = Dependabot::RegistryClient.get(
          url: "#{NIXPKGS_RAW_URL}/#{release.commit}/pkgs/by-name/#{shard}/#{release.attr}/package.nix",
          options: { retry_limit: 0 }
        )
        response.status == 200 ? response.body : nil
      rescue Excon::Error
        nil
      end

      # Extracts owner/repo from the `src = fetchFromGitHub { ... }` block. Both
      # `tag = "v${...}"` and `rev = "<sha>"` pins resolve to the same
      # repo-level Source; the tag vs rev distinction is left to
      # dependabot-core's changelog/commit diffing.
      sig { params(contents: String).returns(T.nilable([String, String])) }
      def parse_github_source(contents)
        match = contents.match(SRC_FETCH_FROM_GITHUB)
        return nil unless match

        block = balanced_block(contents, T.must(match.end(0)))
        return nil unless block

        owner = block[OWNER_ATTR, 1]
        repo = block[REPO_ATTR, 1]
        return nil unless owner&.match?(VALID_GITHUB_NAME) && repo&.match?(VALID_GITHUB_NAME)

        [owner, repo]
      end

      # The text between the opening brace that ends at `start` and its
      # matching closing brace, so `${...}` interpolations inside the block and
      # any later blocks in the file do not cut the match short or extend it.
      sig { params(contents: String, start: Integer).returns(T.nilable(String)) }
      def balanced_block(contents, start)
        depth = 1
        T.must(contents[start..]).each_char.with_index do |char, index|
          depth += 1 if char == "{"
          depth -= 1 if char == "}"
          return contents[start, index] if depth.zero?
        end

        nil
      end
    end
  end
end

Dependabot::MetadataFinders.register("devbox", Dependabot::Devbox::MetadataFinder)

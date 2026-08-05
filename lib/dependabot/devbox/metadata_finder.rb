# typed: strict
# frozen_string_literal: true

require "cgi"
require "json"
require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"
require "dependabot/registry_client"
require "dependabot/source"

module Dependabot
  module Devbox
    class MetadataFinder < Dependabot::MetadataFinders::Base
      extend T::Sig

      SEARCH_URL = "https://search.devbox.sh/v1/search"

      # nixpkgs' `pkgs/by-name/<xx>/<attr>/package.nix` layout, where `<xx>` is
      # the first two characters of the package attribute name.
      NIXPKGS_BY_NAME_URL = "https://raw.githubusercontent.com/NixOS/nixpkgs/master/pkgs/by-name"

      # The `src = fetchFromGitHub { ... };` block in a package.nix. `^\s*\};`
      # anchors the closing brace to its own line so interior `${version}`
      # interpolations don't terminate the match early.
      FETCH_FROM_GITHUB_BLOCK = /fetchFromGitHub\s*\{(.*?)^\s*\};/m
      OWNER_ATTR = /\bowner\s*=\s*"([^"]+)"/
      REPO_ATTR = /\brepo\s*=\s*"([^"]+)"/

      private

      # nixpkgs packages expose a `homepage` in the Nixhub search response. When
      # it points at a recognised git host (e.g. GitHub) we can surface changelog
      # and release metadata directly. Otherwise (e.g. a docs site) fall back to
      # resolving the real source repo from nixpkgs' own derivation.
      sig { override.returns(T.nilable(Dependabot::Source)) }
      def look_up_source
        package = nixhub_package
        return nil unless package

        source_from_homepage(package) || source_from_nixpkgs(package)
      end

      sig { params(package: T::Hash[String, Object]).returns(T.nilable(Dependabot::Source)) }
      def source_from_homepage(package)
        homepage = homepage_for(package)
        return nil unless homepage

        Source.from_url(homepage)
      end

      # Resolve the source repo from nixpkgs' `by-name` derivation when the
      # homepage lookup yields nothing. Bounded to the by-name layout and
      # `fetchFromGitHub`; any miss falls back silently to no source.
      sig { params(package: T::Hash[String, Object]).returns(T.nilable(Dependabot::Source)) }
      def source_from_nixpkgs(package)
        attr = attr_path_for(package)
        return nil unless attr && attr.length >= 2

        contents = fetch_package_nix(attr)
        return nil unless contents

        owner, repo = parse_github_source(contents)
        return nil unless owner && repo

        Source.from_url("https://github.com/#{owner}/#{repo}")
      end

      sig { params(package: T::Hash[String, Object]).returns(T.nilable(String)) }
      def homepage_for(package)
        versions = package["versions"]
        return nil unless versions.is_a?(Array)

        homepage = versions.filter_map { |v| v["homepage"] if v.is_a?(Hash) }.first
        homepage.is_a?(String) && !homepage.empty? ? homepage : nil
      end

      # The nixpkgs attribute name for the package, taken from the search
      # response's `attr_paths` (it can differ from `dependency.name`). It lives
      # per-system under each version; take the first non-empty entry.
      sig { params(package: T::Hash[String, Object]).returns(T.nilable(String)) }
      def attr_path_for(package)
        versions = package["versions"]
        return nil unless versions.is_a?(Array)

        versions.each do |version|
          next unless version.is_a?(Hash)

          systems = version["systems"]
          next unless systems.is_a?(Hash)

          systems.each_value do |system|
            next unless system.is_a?(Hash)

            attr = Array(system["attr_paths"]).find { |a| a.is_a?(String) && !a.empty? }
            return attr if attr
          end
        end

        nil
      end

      sig { params(attr: String).returns(T.nilable(String)) }
      def fetch_package_nix(attr)
        prefix = attr[0, 2]
        response = Dependabot::RegistryClient.get(
          url: "#{NIXPKGS_BY_NAME_URL}/#{prefix}/#{attr}/package.nix"
        )
        return nil unless response.status == 200

        response.body
      rescue Excon::Error::Timeout, Excon::Error::Socket
        nil
      end

      # Extract owner/repo from a `fetchFromGitHub` block. Both `tag = "v${...}"`
      # and `rev = "<sha>"` pins resolve to the same repo-level Source; the tag
      # vs rev distinction is left to dependabot-core's changelog/commit diffing.
      sig { params(contents: String).returns(T.nilable([String, String])) }
      def parse_github_source(contents)
        block = contents[FETCH_FROM_GITHUB_BLOCK, 1]
        return nil unless block

        owner = block[OWNER_ATTR, 1]
        repo = block[REPO_ATTR, 1]
        return nil unless owner && repo

        [owner, repo]
      end

      # The exact-name package in the Nixhub search response (search is fuzzy,
      # so match the name precisely).
      sig { returns(T.nilable(T::Hash[String, Object])) }
      def nixhub_package
        response = Dependabot::RegistryClient.get(
          url: "#{SEARCH_URL}?q=#{CGI.escape(dependency.name)}"
        )
        return nil unless response.status == 200

        data = JSON.parse(response.body)
        packages = data.is_a?(Hash) ? data["packages"] : nil
        return nil unless packages.is_a?(Array)

        packages.find { |pkg| pkg.is_a?(Hash) && pkg["name"] == dependency.name }
      rescue JSON::ParserError, Excon::Error::Timeout, Excon::Error::Socket
        nil
      end
    end
  end
end

Dependabot::MetadataFinders.register("devbox", Dependabot::Devbox::MetadataFinder)

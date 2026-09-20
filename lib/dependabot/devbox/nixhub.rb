# typed: strict
# frozen_string_literal: true

require "cgi"
require "json"
require "sorbet-runtime"
require "dependabot/logger"
require "dependabot/registry_client"

module Dependabot
  module Devbox
    # Thin client for the Nixhub search API shared by the update checker and
    # the metadata finder, so both agree on how a package is looked up and how
    # a failed lookup is reported.
    module Nixhub
      extend T::Sig

      SEARCH_URL = "https://search.devbox.sh/v1/search"

      # The exact-name package from the search response. Search is fuzzy and
      # can return several packages, so match the name precisely. Any network
      # or parse failure is logged and reported as "no package".
      sig { params(name: String).returns(T.nilable(T::Hash[String, Object])) }
      def self.package(name)
        response = Dependabot::RegistryClient.get(url: "#{SEARCH_URL}?q=#{CGI.escape(name)}")
        unless response.status == 200
          Dependabot.logger.warn("Nixhub returned HTTP #{response.status} for #{name}")
          return nil
        end

        data = JSON.parse(response.body)
        packages = data.is_a?(Hash) ? data["packages"] : nil
        return nil unless packages.is_a?(Array)

        packages.find { |pkg| pkg.is_a?(Hash) && pkg["name"] == name }
      rescue JSON::ParserError, Excon::Error => e
        Dependabot.logger.warn("Nixhub lookup for #{name} failed: #{e.class}: #{e.message}")
        nil
      end

      # The version entries of a package payload, dropping anything that is
      # not an object.
      sig { params(package: T.nilable(T::Hash[String, Object])).returns(T::Array[T::Hash[String, Object]]) }
      def self.versions(package)
        versions = package&.fetch("versions", nil)
        return [] unless versions.is_a?(Array)

        versions.grep(Hash)
      end
    end
  end
end

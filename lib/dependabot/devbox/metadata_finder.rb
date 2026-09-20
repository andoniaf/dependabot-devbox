# typed: strict
# frozen_string_literal: true

require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"
require "dependabot/devbox/nixhub"

module Dependabot
  module Devbox
    class MetadataFinder < Dependabot::MetadataFinders::Base
      extend T::Sig

      private

      # nixpkgs packages expose a `homepage` in the Nixhub search response. When
      # it points at a recognised git host (e.g. GitHub) we can surface changelog
      # and release metadata; otherwise there is no usable source.
      sig { override.returns(T.nilable(Dependabot::Source)) }
      def look_up_source
        homepage = nixhub_homepage
        return nil unless homepage

        Source.from_url(homepage)
      end

      sig { returns(T.nilable(String)) }
      def nixhub_homepage
        versions = Nixhub.versions(Nixhub.package(dependency.name))
        homepage = versions.filter_map { |v| v["homepage"] }.first
        homepage.is_a?(String) && !homepage.empty? ? homepage : nil
      end
    end
  end
end

Dependabot::MetadataFinders.register("devbox", Dependabot::Devbox::MetadataFinder)

# typed: strong
# frozen_string_literal: true

require "dependabot/version"
require "dependabot/utils"
require "sorbet-runtime"

# Devbox package versions are nixpkgs versions. Alongside standard numeric
# versions ("3.10.19") and short prefixes ("3", "3.10"), nixpkgs uses
# date-style releases ("2025-04-04"), snapshot builds ("unstable-2024-01-01",
# "0-unstable-2024-01-01") and semver build metadata ("1.8.2+git"). Devbox
# adds a "latest" sentinel that always resolves to the newest release, so it
# must sort above any concrete version.
#
# The original string is kept for display; a normalised copy that Gem::Version
# can parse drives comparison:
#   - build metadata after "+" is dropped (semver ignores it for ordering)
#   - "-" between digits becomes "." so date releases are not prereleases
#   - a leading alphabetic segment is prefixed with "0-" so it parses, which
#     also marks snapshot builds as prereleases

module Dependabot
  module Devbox
    class Version < Dependabot::Version
      extend T::Sig

      LATEST = "latest"

      # nixpkgs version strings: alphanumerics plus ".", "_", "+" and "-",
      # containing at least one digit.
      NIXPKGS_VERSION = /\A(?=.*\d)[A-Za-z0-9][A-Za-z0-9._+-]*\z/

      sig { override.params(version: VersionParameter).returns(T::Boolean) }
      def self.correct?(version)
        return false if version.nil?

        string = version.to_s.strip
        return true if string == LATEST
        return false unless string.match?(NIXPKGS_VERSION)

        Gem::Version.correct?(normalize(string))
      end

      sig { params(version: String).returns(String) }
      def self.normalize(version)
        normalized = version.sub(/\+.*\z/, "").gsub(/(?<=\d)-(?=\d)/, ".")
        normalized.match?(/\A\d/) ? normalized : "0-#{normalized}"
      end

      sig { override.params(version: VersionParameter).void }
      def initialize(version)
        @version_string = T.let(version.to_s.strip, String)
        @latest = T.let(@version_string == LATEST, T::Boolean)

        super(@latest ? "0" : self.class.normalize(@version_string))
      end

      sig { override.params(version: VersionParameter).returns(Dependabot::Devbox::Version) }
      def self.new(version)
        T.cast(super, Dependabot::Devbox::Version)
      end

      sig { returns(T::Boolean) }
      def latest?
        @latest
      end

      sig { override.params(other: T.untyped).returns(T.nilable(Integer)) }
      def <=>(other)
        other = self.class.new(other) if other.is_a?(String) && self.class.correct?(other)
        return nil unless other.is_a?(Gem::Version)

        other_latest = other.is_a?(self.class) && other.latest?
        return 0 if latest? && other_latest
        return 1 if latest?
        return -1 if other_latest

        super
      end

      sig { override.returns(T::Boolean) }
      def prerelease?
        return false if latest?

        super
      end

      sig { override.params(other: T.untyped).returns(T::Boolean) }
      def eql?(other)
        other.is_a?(self.class) && latest? == other.latest? && super
      end

      sig { override.returns(Integer) }
      def hash
        latest? ? LATEST.hash : super
      end

      sig { override.returns(String) }
      def to_s
        @version_string
      end

      sig { override.returns(String) }
      def inspect
        "#<#{self.class} #{@version_string}>"
      end
    end
  end
end

Dependabot::Utils.register_version_class("devbox", Dependabot::Devbox::Version)

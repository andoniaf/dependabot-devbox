# typed: strict
# frozen_string_literal: true

require "json"
require "sorbet-runtime"

require "dependabot/errors"
require "dependabot/shared_helpers"

module Dependabot
  module Devbox
    module Helpers
      extend T::Sig

      # Matches either a JSON string literal (with escapes), a line comment, a
      # block comment, or a trailing comma. The alternation lets gsub preserve
      # strings while stripping the JSONC-only constructs, so e.g. "//" inside a
      # URL value is not mistaken for the start of a comment.
      JSONC_TOKEN = %r{
          ("(?:\\.|[^"\\])*")    # JSON string literal
          | //[^\n]*             # line comment
          | /\*.*?\*/            # block comment
          | ,(?=\s*[\}\]])       # trailing comma
        }mx

      sig { params(raw: T.nilable(String)).returns(T::Array[String]) }
      def self.parse_exclude_list(raw)
        return [] unless raw

        raw.split(/[\s,]+/).reject(&:empty?).uniq
      end

      sig { params(content: T.nilable(String)).returns(T::Hash[String, Object]) }
      def self.parse_json_or_jsonc(content)
        return {} unless content

        cleaned = content.gsub(JSONC_TOKEN) { ::Regexp.last_match(1) || "" }

        parsed = JSON.parse(cleaned)
        # A devbox.json must be a JSON object. Guard here so a malformed manifest
        # (e.g. a top-level array) surfaces as a clear parse error rather than an
        # opaque sorbet-runtime type error at the call site.
        raise JSON::ParserError, "Expected a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

        parsed
      end

      # Finds the dependency file with the given basename, matching how the
      # fetcher names files relative to the source directory.
      sig do
        params(files: T::Array[Dependabot::DependencyFile], filename: String)
          .returns(T.nilable(Dependabot::DependencyFile))
      end
      def self.find_file(files, filename)
        files.find { |f| File.basename(f.name) == filename }
      end

      sig { returns(T::Boolean) }
      def self.devbox_available?
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |path|
          File.executable?(File.join(path, "devbox"))
        end
      end

      # Wraps `devbox <args>` via Dependabot's standard subprocess helper, so
      # failures surface as Dependabot::SharedHelpers::HelperSubprocessFailed
      # (consistent with cargo / bun / npm_and_yarn). Only devbox's own cache
      # is scoped to the working directory: HOME is left alone so the nix
      # configuration (access tokens) and nix caches of the host are used.
      sig do
        params(
          args: String,
          dir: String
        ).returns(String)
      end
      def self.run_devbox_command(*args, dir:)
        raise Dependabot::DependabotError, "devbox CLI not found on PATH" unless devbox_available?

        Dependabot::SharedHelpers.run_shell_command(
          "devbox #{args.join(' ')}",
          cwd: dir,
          env: { "DEVBOX_CACHE" => File.join(dir, ".devbox_cache") }
        )
      end
    end
  end
end

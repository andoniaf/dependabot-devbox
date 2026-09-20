# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/devbox/helpers"
require "dependabot/shared_helpers"
require "dependabot/dependency_file"
require "tmpdir"

RSpec.describe Dependabot::Devbox::Helpers do
  describe ".parse_json_or_jsonc" do
    it "returns an empty hash for nil content" do
      expect(described_class.parse_json_or_jsonc(nil)).to eq({})
    end

    it "parses JSON with comments and trailing commas" do
      content = <<~JSONC
        {
          // a line comment
          /* a block comment */
          "packages": [
            "python@3.10",
            "ripgrep@latest",
          ],
        }
      JSONC
      expect(described_class.parse_json_or_jsonc(content))
        .to eq("packages" => ["python@3.10", "ripgrep@latest"])
    end

    it "does not treat // inside a string value as a comment" do
      content = <<~JSONC
        {
          "$schema": "https://raw.githubusercontent.com/jetify-com/devbox/0.13.0/.schema/devbox.schema.json"
        }
      JSONC
      expect(described_class.parse_json_or_jsonc(content))
        .to eq(
          "$schema" => "https://raw.githubusercontent.com/jetify-com/devbox/0.13.0/.schema/devbox.schema.json"
        )
    end

    it "raises a clear error when the top-level value is not an object" do
      expect do
        described_class.parse_json_or_jsonc("[1, 2, 3]")
      end.to raise_error(JSON::ParserError, /Expected a JSON object/)
    end
  end

  describe ".parse_exclude_list" do
    it "returns an empty array for nil" do
      expect(described_class.parse_exclude_list(nil)).to eq([])
    end

    it "returns an empty array for an empty string" do
      expect(described_class.parse_exclude_list("")).to eq([])
    end

    it "splits on whitespace" do
      expect(described_class.parse_exclude_list("go nodejs")).to eq(%w[go nodejs])
    end

    it "splits on commas" do
      expect(described_class.parse_exclude_list("go,nodejs")).to eq(%w[go nodejs])
    end

    it "splits on mixed whitespace and commas" do
      expect(described_class.parse_exclude_list(" go,  nodejs ,ripgrep\n")).to eq(%w[go nodejs ripgrep])
    end

    it "dedupes repeated names" do
      expect(described_class.parse_exclude_list("go go nodejs")).to eq(%w[go nodejs])
    end
  end

  describe ".run_devbox_command" do
    let(:dir) { "/tmp/some-dir" }

    before { allow(described_class).to receive(:devbox_available?).and_return(true) }

    it "delegates to SharedHelpers.run_shell_command with a scoped devbox cache" do
      allow(Dependabot::SharedHelpers).to receive(:run_shell_command)
        .with(
          "devbox update python",
          cwd: dir,
          env: { "DEVBOX_CACHE" => "#{dir}/.devbox_cache" }
        )
        .and_return("ok\n")

      result = described_class.run_devbox_command("update", "python", dir: dir)
      expect(result).to eq("ok\n")
    end

    it "leaves HOME alone so the host nix configuration and caches are used" do
      allow(Dependabot::SharedHelpers).to receive(:run_shell_command).and_return("")

      described_class.run_devbox_command("update", dir: dir)

      expect(Dependabot::SharedHelpers).to have_received(:run_shell_command)
        .with(anything, hash_including(env: hash_excluding("HOME", "XDG_CACHE_HOME")))
    end

    it "propagates HelperSubprocessFailed on non-zero exit" do
      allow(Dependabot::SharedHelpers).to receive(:run_shell_command)
        .and_raise(
          Dependabot::SharedHelpers::HelperSubprocessFailed.new(
            message: "boom",
            error_context: { command: "devbox update" }
          )
        )

      expect do
        described_class.run_devbox_command("update", dir: dir)
      end.to raise_error(Dependabot::SharedHelpers::HelperSubprocessFailed, /boom/)
    end

    it "raises a clear error when the devbox CLI is not installed" do
      allow(described_class).to receive(:devbox_available?).and_return(false)
      allow(Dependabot::SharedHelpers).to receive(:run_shell_command)

      expect { described_class.run_devbox_command("update", dir: dir) }
        .to raise_error(Dependabot::DependabotError, /devbox CLI not found/)
      expect(Dependabot::SharedHelpers).not_to have_received(:run_shell_command)
    end
  end

  describe ".devbox_available?" do
    it "is true when a devbox executable is on PATH" do
      Dir.mktmpdir do |bin|
        exe = File.join(bin, "devbox")
        File.write(exe, "#!/bin/sh\n")
        File.chmod(0o755, exe)
        stub_const("ENV", ENV.to_h.merge("PATH" => bin))

        expect(described_class.devbox_available?).to be true
      end
    end

    it "is false when PATH has no devbox executable" do
      Dir.mktmpdir do |bin|
        stub_const("ENV", ENV.to_h.merge("PATH" => bin))

        expect(described_class.devbox_available?).to be false
      end
    end
  end

  describe ".find_file" do
    it "matches on the basename" do
      manifest = Dependabot::DependencyFile.new(name: "services/api/devbox.json", content: "{}")
      lockfile = Dependabot::DependencyFile.new(name: "services/api/devbox.lock", content: "{}")

      expect(described_class.find_file([lockfile, manifest], "devbox.json")).to eq(manifest)
      expect(described_class.find_file([manifest], "devbox.lock")).to be_nil
    end
  end
end

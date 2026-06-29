# typed: false
# frozen_string_literal: true

require "webmock/rspec"
require "webmock/http_lib_adapters/excon_adapter"
require "vcr"
require "rspec/sorbet"

require "dependabot/dependency_file"
require "dependabot/experiments"
require "dependabot/registry_client"

ENV["GIT_AUTHOR_NAME"] = "dependabot-ci"
ENV["GIT_AUTHOR_EMAIL"] = "no-reply@github.com"
ENV["GIT_COMMITTER_NAME"] = "dependabot-ci"
ENV["GIT_COMMITTER_EMAIL"] = "no-reply@github.com"

RSpec.configure do |config|
  config.color = true
  config.order = :rand
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.expect_with(:rspec) { |expectations| expectations.max_formatted_output_length = 1000 }
  config.raise_errors_for_deprecations!
  config.example_status_persistence_file_path = ".rspec_status"

  config.after do
    Dependabot::RegistryClient.clear_cache!
    Dependabot::Experiments.reset!
  end
end

RSpec::Sorbet.allow_doubles!

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  config.before_record do |interaction|
    interaction.response.headers.transform_keys!(&:downcase).delete("set-cookie")
    interaction.request.headers.transform_keys!(&:downcase).delete("authorization")
    uri = URI.parse(interaction.request.uri)
    interaction.request.uri.sub!(%r{:\/\/.*#{Regexp.escape(uri.host)}}, "://#{uri.host}")
  end

  record_mode = ENV["VCR"] ? ENV["VCR"].to_sym : :none
  config.default_cassette_options = { record: record_mode }
end

def fixture(*name)
  File.read(File.join("spec", "fixtures", File.join(*name)))
end

def build_tmp_repo(project, path: "projects", tmp_dir_path: nil, tmp_dir_prefix: nil)
  require "dependabot/utils"
  tmp_dir_path  ||= Dependabot::Utils::BUMP_TMP_DIR_PATH
  tmp_dir_prefix ||= Dependabot::Utils::BUMP_TMP_FILE_PREFIX

  project_path = File.expand_path(File.join("spec/fixtures", path, project))
  FileUtils.mkdir_p(tmp_dir_path)
  tmp_repo      = Dir.mktmpdir(tmp_dir_prefix, tmp_dir_path)
  tmp_repo_path = Pathname.new(tmp_repo).expand_path
  FileUtils.cp_r("#{project_path}/.", tmp_repo_path)

  Dir.chdir(tmp_repo_path) do
    Dependabot::SharedHelpers.run_shell_command("git init")
    Dependabot::SharedHelpers.run_shell_command("git add --all")
    Dependabot::SharedHelpers.run_shell_command("git commit -m init")
  end

  tmp_repo_path.to_s
end

def project_dependency_files(project, directory: "/")
  project_path = File.expand_path(File.join("spec/fixtures/projects", project, directory))
  raise "Fixture does not exist for project: '#{project}'" unless Dir.exist?(project_path)

  Dir.chdir(project_path) do
    files = Dir.glob("**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) }
    files.map do |filename|
      Dependabot::DependencyFile.new(
        name: filename,
        content: File.read(filename),
        directory: directory
      )
    end
  end
end

def github_credentials
  token = ENV["DEPENDABOT_TEST_ACCESS_TOKEN"] || ENV["LOCAL_GITHUB_ACCESS_TOKEN"]
  return [] unless token

  [{ "type" => "git_source", "host" => "github.com", "username" => "x-access-token", "password" => token }]
end

require "test_helper"
require "open3"

class Repository::SelfHostedSyncTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @root = Pathname(Dir.mktmpdir)
    settings = {
      "REPLICA_BUILD_RUNNER" => "self_hosted",
      "REPLICA_SELF_HOSTED_BUILD_ROOT" => @root.join("builds").to_s,
      "REPLICA_SELF_HOSTED_REPOS_ROOT" => @root.join("repos").to_s,
      "REPLICA_NPM_CACHE_DIR" => @root.join("npm-cache").to_s
    }
    @original = settings.keys.index_with { ENV[_1] }
    ENV.update(settings)
    @configuration = github_app_configurations.create_installed
  end

  teardown do
    ENV.update(@original)
    FileUtils.remove_entry(@root)
  end

  test "a mirror builds the recorded revision and retires a deleted branch after a successful fetch" do
    repository = repositories.create
    sync = repository.self_hosted_sync
    token = "example-read-token"
    stub_request(:post, "#{GITHUB_API_URL}/app/installations/456/access_tokens")
      .with(body: { repository_ids: [ repository.github_id ], permissions: { contents: "read" } }.to_json)
      .to_return(status: 201, body: { token: }.to_json)
    remote = @root.join("remote")
    git!(@root, "init", "-b", "main", remote.to_s)
    git!(remote, "config", "user.name", "Example Author")
    git!(remote, "config", "user.email", "author@example.invalid")
    package = { name: "example", version: "1.0.0", scripts: { build: "mkdir dist && echo original > dist/index.html" } }
    remote.join("package.json").write(package.to_json)
    remote.join("package-lock.json").write({ lockfileVersion: 3, packages: { "" => package.except(:scripts) } }.to_json)
    git!(remote, "add", ".")
    git!(remote, "commit", "-m", "buildable prototype")
    git!(remote, "branch", "prototype/example")
    FileUtils.mkdir_p(sync.mirror.dirname)
    git!(@root, "init", "--bare", sync.mirror.to_s)
    url = "#{Rails.configuration.x.github_url}/#{repository.github_path}.git"
    git!(sync.mirror, "config", "url.#{remote}.insteadOf", url)

    @configuration.define_singleton_method(:synchronize_repositories!) { nil }
    assert_enqueued_jobs 2, queue: "self_hosted_builds" do
      @configuration.discover_builds!(repository)
    end
    prototype = repository.prototypes.find_by!(branch_name: "prototype/example")
    build = prototype.current_build
    assert_equal git!(remote, "rev-parse", "HEAD"), build.commit_sha
    assert_equal "Example Author", build.commit_author_name
    config = sync.mirror.join("config").read
    assert_not_includes config, token
    assert_not_includes config, Base64.strict_encode64("x-access-token:#{token}")

    git!(remote, "branch", "-D", "prototype/example")
    git!(remote, "rm", "package.json")
    git!(remote, "commit", "-m", "invalid package")
    @configuration.discover_builds!(repository)
    assert prototype.reload.branch_deleted_at
    store = ArtifactStore.new(adapter: ArtifactStore::Local.new(root: @root.join("artifacts")))
    build.self_hosted_package.create!(artifact_store: store)
    assert_equal "successful", build.reload.state, build.failure_summary
    assert store.exist?("builds/#{build.id}/screenshots/desktop.png")
    failed = repository.replica_build_owner.current_build
    failed.self_hosted_package.create!(artifact_store: store)
    assert_equal "failed", failed.reload.state
    assert_empty store.list("builds/#{failed.id}")
    assert_empty @root.join("builds").children
    assert_equal 1, git!(sync.mirror, "worktree", "list", "--porcelain").scan(/^worktree /).size

    FileUtils.mv(remote, @root.join("unavailable"))
    error = assert_raises(GithubClient::Error) { @configuration.discover_builds!(repository) }
    assert_equal "Git fetch failed", error.message
  end

  test "fetch uses a scoped header outside argv and discards credential-bearing git diagnostics" do
    repository = repositories.create
    sync = repository.self_hosted_sync
    FileUtils.mkdir_p(sync.mirror.dirname)
    git!(@root, "init", "--bare", sync.mirror.to_s)
    stub_github_installation_token

    probe = @root.join("git")
    probe.write(<<~'SH')
      #!/bin/sh
      printf '%s\n' "$@" > "$2/probe-arguments"
      printf '%s\n' "$GIT_CONFIG_KEY_0" "$GIT_CONFIG_VALUE_0" > "$2/probe-header"
      printf '%s\n' "$GIT_CONFIG_VALUE_0" >&2
      exit 1
    SH
    probe.chmod(0o700)
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{@root}:#{original_path}"
    error = assert_raises(GithubClient::Error) do
      sync.synchronize!(configuration: @configuration, installation: @configuration.installation_snapshot)
    end
    encoded = Base64.strict_encode64("x-access-token:installation-token")
    assert_match(/Authorization: Basic #{Regexp.escape(encoded)}/, sync.mirror.join("probe-header").read)
    args = sync.mirror.join("probe-arguments").read
    assert_includes args.lines.map(&:chomp), "fetch"
    [ args, error.message, sync.mirror.join("config").read ].each do |value|
      assert_not_includes value, "installation-token"
      assert_not_includes value, encoded
    end
  ensure
    ENV["PATH"] = original_path if original_path
  end

  private

  def git!(path, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", path.to_s, *args)
    assert status.success?, stderr
    stdout.strip
  end
end

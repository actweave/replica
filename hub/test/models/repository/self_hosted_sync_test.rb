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
    remote = prepare_remote(repository)

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

    git!(remote, "branch", "prototype/example")
    head_sha = git!(remote, "rev-parse", "HEAD")
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/repos/#{repository.github_path}/compare/#{build.commit_sha}...#{head_sha}")
      .to_return do
        File.open("#{sync.mirror}.lock", "w") do |lock|
          assert lock.flock(File::LOCK_EX | File::LOCK_NB), "worktree cleanup must be able to lock the mirror during compare"
        end
        { status: 200, body: { status: "ahead", base_commit: { sha: build.commit_sha },
          merge_base_commit: { sha: build.commit_sha } }.to_json }
      end
    @configuration.discover_builds!(repository)
    assert_nil prototype.reload.branch_deleted_at

    FileUtils.mv(remote, @root.join("unavailable"))
    error = assert_raises(GithubClient::Error) { @configuration.discover_builds!(repository) }
    assert_equal "Git fetch failed", error.message
  end

  test "switching runners adopts unfinished heads and preserves a published Actions package" do
    repository = repositories.create
    remote = prepare_remote(repository)
    git!(remote, "branch", "completed")
    sha = git!(remote, "rev-parse", "HEAD")
    stub_github_installation_token
    store = ArtifactStore.new(adapter: ArtifactStore::Local.new(root: @root.join("artifacts")))
    running, completed, published = %w[main completed prototype/example].map.with_index do |branch, index|
      build = repository.build_discoveries.record!(branch_name: branch, commit_sha: sha, branch_head: true)
      build.workflow_run.record!(run_id: 9001 + index, run_attempt: 1,
        workflow_url: "#{GITHUB_URL}/example/prototype/actions/runs/#{9001 + index}", workflow_created_at: Time.current,
        stage: index.zero? ? "in_progress" : "completed", conclusion: "success")
      build
    end
    prefix = "builds/#{published.id}"
    published.update!(state: "successful", github_artifact_id: 8001, finished_at: Time.current,
      artifact_prefix: prefix, artifact_bytes: 8)
    store.write("#{prefix}/dist/index.html", source: StringIO.new("retained"))

    sync = repository.self_hosted_sync
    assert_enqueued_jobs 2, queue: "self_hosted_builds" do
      sync.synchronize!(configuration: @configuration, installation: @configuration.installation_snapshot)
    end
    [ running, completed ].each do |build|
      assert_equal "queued", build.reload.state
      assert_nil build.workflow_completed_at
      assert_nil build.started_at
      assert build.github_workflow_run_id
      build.self_hosted_package.create!(artifact_store: store)
      assert_equal "successful", build.reload.state, build.failure_summary
      assert_predicate build, :self_hosted?
      assert store.exist?("builds/#{build.id}/screenshots/desktop.png")
    end
    assert_equal 8001, published.reload.github_artifact_id
    assert_equal prefix, published.artifact_prefix
    destination = StringIO.new
    store.read("#{prefix}/dist/index.html", destination:)
    assert_equal "retained", destination.string
  end

  test "a timed-out worker keeps its claim during refresh and removes its partial package and worktree" do
    repository = repositories.create
    prepare_remote(repository)
    stub_github_installation_token
    sync = repository.self_hosted_sync
    sync.synchronize!(configuration: @configuration, installation: @configuration.installation_snapshot)
    build = repository.replica_build_owner.current_build
    build.workflow_run.record!(run_id: 9001, run_attempt: 1, workflow_url: "#{GITHUB_URL}/example/prototype/actions/runs/9001",
      workflow_created_at: Time.current, stage: "requested", conclusion: nil)
    store = ArtifactStore.new(adapter: ArtifactStore::Local.new(root: @root.join("artifacts")))
    package = build.self_hosted_package
    package.define_singleton_method(:package_timeout) { 2.seconds }
    pid_path = @root.join("pid")
    package.define_singleton_method(:build_package) do |checkout, _directory|
      build.self_hosted_package.enqueue!
      raise "Claim lost" unless build.reload.state == "running"

      store.write("builds/#{build.id}/dist/partial", source: StringIO.new("partial"))
      run!(RbConfig.ruby, "-e", "File.write(ARGV.first, Process.pid); sleep 30", pid_path.to_s, chdir: checkout)
    end
    package.create!(artifact_store: store)

    assert_equal "failed", build.reload.state
    assert_includes build.failure_summary, "exceeded 15 minutes"
    assert_raises(Errno::ESRCH) { Process.kill(0, Integer(pid_path.read)) }
    assert_empty store.list("builds/#{build.id}")
    assert_empty @root.join("builds").children
    assert_equal 1, git!(sync.mirror, "worktree", "list", "--porcelain").scan(/^worktree /).size
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

  def prepare_remote(repository)
    sync = repository.self_hosted_sync
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
    remote
  end

  def git!(path, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", path.to_s, *args)
    assert status.success?, stderr
    stdout.strip
  end
end

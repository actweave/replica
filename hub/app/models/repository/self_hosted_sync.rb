require "base64"
require "open3"
require "timeout"

# Maintains a mirror for one installed repository. All mirror mutations share its lock.
class Repository::SelfHostedSync < ActiveRecord::AssociatedObject
  PROXY_KEYS = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].freeze

  def self.enabled?
    !LocalDevelopment.enabled? && ENV["REPLICA_BUILD_RUNNER"] == "self_hosted"
  end

  def mirror
    Rails.root.join(ENV["REPLICA_SELF_HOSTED_REPOS_ROOT"].presence || "storage/repos", "#{repository.id}.git")
  end

  def synchronize!(configuration:, installation:)
    # Keep scans ordered while allowing worktree cleanup during remote ancestry checks.
    with_lock("#{mirror}.scan.lock") do
      return unless repository.reload.installation_state == "active" && !repository.local?

      observations = repository.branch_presence.observations
      heads = with_lock do
        fetch!(configuration)
        git!("for-each-ref", "--format=%(refname:strip=2)%00%(objectname)%00%(authorname)", "refs/heads")
      end
      heads.each_line do |row|
        branch_name, commit_sha, author = row.scrub.chomp.split("\0", 3)
        next unless repository.build_branch?(branch_name)

        build = repository.branch_presence.record_head!(branch_name:, commit_sha:,
          observed: observations.delete(branch_name), configuration:, installation:)
        next unless build

        build.with_lock do
          build.update!(commit_author_name: author.strip.first(255)) if author.present? && build.commit_author_name.nil?
        end
        build.self_hosted_package.enqueue!
      end
      configuration.with_installation!(snapshot: installation) do
        observations.each { |name, observed| repository.branch_presence.record_missing!(branch_name: name, observed:) }
      end
    end
  end

  def with_lock(path = "#{mirror}.lock")
    FileUtils.mkdir_p(mirror.dirname)
    File.open(path, "w", 0o600) do |file|
      file.flock(File::LOCK_EX)
      yield
    end
  end

  def ensure_commit!(sha)
    git!("cat-file", "-e", "#{sha}^{commit}")
  rescue GithubClient::Error
    fetch!(GithubAppConfiguration.current)
    git!("cat-file", "-e", "#{sha}^{commit}")
  end

  private

  def fetch!(configuration)
    raise GithubClient::Error, "Installation unavailable" unless configuration&.installation_state == "active"

    git!("init", "--bare", mirror.to_s, directory: mirror.dirname) unless mirror.join("HEAD").file?
    url = "#{Rails.configuration.x.github_url.delete_suffix("/")}/#{repository.github_path}.git"
    raise GithubClient::Error, "Git fetch requires HTTPS" unless URI.parse(url).is_a?(URI::HTTPS)

    token = configuration.tokens.repository_reader(repository.github_id)
    auth = Base64.strict_encode64("x-access-token:#{token}")
    git!("fetch", "--prune", "--no-tags", url, "+refs/heads/*:refs/heads/*",
      environment: { "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "http.#{url}.extraHeader",
        "GIT_CONFIG_VALUE_0" => "Authorization: Basic #{auth}" })
  end

  # Git diagnostics can include HTTP headers. Only return ref data after a successful command.
  def git!(*arguments, environment: {}, directory: mirror)
    env = ENV.to_h.slice("PATH", *PROXY_KEYS).merge(environment, "GIT_TERMINAL_PROMPT" => "0",
      "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL)
    Open3.popen2(env, "git", "-C", directory.to_s, *arguments, err: File::NULL, unsetenv_others: true,
      pgroup: true) do |input, stdout, wait|
      input.close
      begin
        output, status = Timeout.timeout(2.minutes) { [ stdout.read, wait.value ] }
        raise GithubClient::Error, "Git #{arguments.first} failed" unless status.success?

        output
      ensure
        begin
          Process.kill("KILL", -wait.pid) unless status
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end

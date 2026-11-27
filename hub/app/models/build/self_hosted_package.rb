# Packages one exact mirror commit with a persistent, online-capable npm cache.
class Build::SelfHostedPackage < Build::WorktreePackage
  class StageFailure < StandardError; end

  # An Actions importer owns the prefix once it has selected an artifact under the row lock.
  def enqueue!
    build.with_lock do
      return unless eligible?(build.prototype.repository) && build.state.in?(%w[queued running])

      if build.github_artifact_id.present?
        build.import_package_later!
        return
      end

      if build.state == "running" && build.github_workflow_run_id.present? && !build.self_hosted?
        build.update!(state: "queued", started_at: nil, workflow_completed_at: nil)
      end
      build.build_self_hosted_package_later! if build.state == "queued"
    end
  end

  private

  def eligible?(repository)
    Repository::SelfHostedSync.enabled? && !repository.local? && repository.installation_state == "active"
  end

  def claim!
    build.update!(state: "running", started_at: Time.current, self_hosted: true)
  end

  def sync = build.prototype.repository.self_hosted_sync

  def add_checkout(checkout)
    sync.with_lock do
      sync.ensure_commit!(build.commit_sha)
      worktree!("add", "--detach", checkout, build.commit_sha)
    end
  end

  def remove_checkout(checkout)
    sync.with_lock do
      begin
        worktree!("remove", "--force", checkout)
      rescue StageFailure
        FileUtils.remove_entry(checkout) if File.exist?(checkout)
        worktree!("prune", "--expire", "now")
        raise
      end
    end
  end

  def worktree!(*arguments)
    run!("git", "-C", sync.mirror.to_s, "-c", "core.hooksPath=#{File::NULL}", "worktree", *arguments,
      environment: { "PATH" => ENV.fetch("PATH"), "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" })
  end

  def workspace = Rails.root.join(ENV["REPLICA_SELF_HOSTED_BUILD_ROOT"].presence || "storage/self_hosted_builds")

  def action_root
    default = Rails.env.production? ? "/opt/replica/actions-build" : "../actions/build"
    Rails.root.join(ENV["REPLICA_BUILD_ACTION_ROOT"].presence || default).expand_path
  end

  def package_timeout = 15.minutes
  def install_flag = "--prefer-offline"

  def npm_environment
    ENV.to_h.slice(*Repository::SelfHostedSync::PROXY_KEYS).merge("npm_config_prefer_offline" => "true",
      "npm_config_cache" => Rails.root.join(ENV["REPLICA_NPM_CACHE_DIR"].presence || "storage/npm-cache").to_s)
  end

  # Only fixed stage names can appear in the public failure summary.
  def run!(command, *arguments, **options)
    super
  rescue LocalDevelopment::Error
    stage = case command
    when "node" then File.basename(File.dirname(arguments.first))
    when "npm" then "npm #{arguments.first}"
    else "worktree setup or cleanup"
    end
    raise StageFailure, "Self-hosted build failed during #{stage}"
  end

  def failure_message(error)
    return error.message if error.is_a?(StageFailure)
    return "Self-hosted build exceeded 15 minutes" if error.is_a?(Timeout::Error)

    "Self-hosted build failed"
  end
end

# Packages a configured developer checkout using its offline dependency cache.
class Build::LocalPackage < Build::WorktreePackage
  private

  def eligible?(repository)
    LocalDevelopment.enabled? && repository.local?
  end

  def add_checkout(checkout)
    repository = build.prototype.repository
    @path = repository.local_path
    unless LocalDevelopment.repository_available?(@path, identity: repository.local_identity)
      raise LocalDevelopment::Error, "Local repository is no longer configured: #{@path}"
    end

    run!("git", "-C", @path, "worktree", "add", "--detach", checkout, build.commit_sha)
  end

  def remove_checkout(checkout)
    run!("git", "-C", @path, "worktree", "remove", "--force", checkout)
  end

  def workspace = Rails.root.join("storage/local_builds")
  def action_root = Rails.root.join("../actions/build").expand_path
  def install_flag = "--offline"

  def npm_environment
    { "npm_config_offline" => "true", "npm_config_cache" => ENV.fetch("npm_config_cache", File.join(ENV.fetch("HOME"), ".npm")) }
  end

  def run!(command, ...)
    super
  rescue Timeout::Error
    raise LocalDevelopment::Error, "#{command} exceeded the 15-minute build limit"
  end

  def failure_message(error) = "Local build failed: #{error.message.to_s.first(950)}"
end

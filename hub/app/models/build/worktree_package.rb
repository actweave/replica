require "fileutils"
require "open3"
require "timeout"
require "tmpdir"
require "zip"

# Packages an exact Git revision and publishes only after validation and checkout cleanup.
class Build::WorktreePackage < ActiveRecord::AssociatedObject
  # Builds in an isolated git worktree so the author's working tree remains untouched.
  def create!(artifact_store: ArtifactStore.current)
    build.reload
    return if build.state != "queued" || !eligible?(build.prototype.repository)

    build.with_lock do
      return if build.state != "queued"

      claim!
    end
    claimed = true
    FileUtils.mkdir_p(workspace)
    prefix = "builds/#{build.id}"
    bytes = Dir.mktmpdir("build-#{build.id}-", workspace.to_s) do |directory|
      checkout = File.join(directory, "checkout")
      added = false
      begin
        Timeout.timeout(package_timeout) do
          add_checkout(checkout)
          added = true
          package = build_package(checkout, directory)
          artifact_store.delete_prefix(prefix)
          File.open(package, "rb") do |file|
            Build::PackageExtraction.new(artifact_store:).extract!(file, prefix:)
          end
        end
      ensure
        remove_checkout(checkout) if added || File.exist?(checkout)
      end
    end
    build.with_lock do
      now = Time.current
      build.update! \
        state: "successful",
        finished_at: now,
        local_package_completed_at: now,
        artifact_prefix: prefix,
        artifact_bytes: bytes
    end
  rescue StandardError => error
    raise unless claimed

    begin
      artifact_store.delete_prefix("builds/#{build.id}") if build.state != "successful"
    rescue StandardError => cleanup_error
      Rails.logger.error("Could not clean up local Build #{build.id}: #{cleanup_error.full_message}")
    ensure
      build.with_lock do
        if build.state == "running"
          build.update!(state: "failed", finished_at: Time.current,
            failure_summary: failure_message(error))
        end
      end
    end
  end

  # Finds Chromium for screenshots: a configured executable, then the image's own, then the
  # browsers Playwright installed for the person running Hub. Builds get a throwaway HOME, so
  # Playwright would otherwise look for those under it, as npm would for its cache. Relative
  # paths count from the build action, where Chromium is installed, because the screenshot step
  # runs from another directory. A relative XDG_CACHE_HOME is ignored, as the XDG specification
  # requires, and Playwright's special browsers path "0" passes through unchanged.
  def self.browser_environment(env: ENV, system_chromium: "/usr/bin/chromium", macos: RUBY_PLATFORM.include?("darwin"),
    action: Rails.root.join("../actions/build").expand_path.to_s)
    executable = env["PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH"].presence
    executable ||= system_chromium if File.executable?(system_chromium)
    return { "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" => File.expand_path(executable, action) } if executable

    browsers = env["PLAYWRIGHT_BROWSERS_PATH"].presence
    return { "PLAYWRIGHT_BROWSERS_PATH" => browsers == "0" ? browsers : File.expand_path(browsers, action) } if browsers

    home = env.fetch("HOME")
    xdg = env["XDG_CACHE_HOME"].presence
    cache = if macos
      File.join(home, "Library/Caches")
    elsif xdg && Pathname(xdg).absolute?
      xdg
    else
      File.join(home, ".cache")
    end
    { "PLAYWRIGHT_BROWSERS_PATH" => File.join(cache, "ms-playwright") }
  end

  private

  def claim!
    build.update!(state: "running", started_at: Time.current)
  end

  def package_timeout = nil

  # Uses the shared build scripts to enforce the action's dist and screenshot contract.
  def build_package(checkout, directory)
    action = action_root
    scripts = action.join("scripts")
    environment = {
      "PATH" => ENV.fetch("PATH"),
      "HOME" => directory,
      "CI" => "true"
    }.merge(npm_environment)
    if !action.join("node_modules/playwright").directory?
      run!("npm", "ci", install_flag, "--ignore-scripts", "--omit=dev",
        chdir: action.to_s, environment:)
    end
    run!("node", scripts.join("validate-repository/index.ts").to_s,
      "--root", checkout, environment:)
    run!("npm", "ci", install_flag, chdir: checkout, environment:)
    run!("npm", "run", "build", chdir: checkout, environment:)
    run!("node", scripts.join("validate-build-output/index.ts").to_s,
      "--root", checkout, environment:)
    screenshots = File.join(directory, "screenshots")
    run!("node", scripts.join("capture-screenshots/index.ts").to_s,
      "--root", checkout, "--screenshots", screenshots,
      environment: environment.merge(self.class.browser_environment(action: action.to_s)))
    output = File.join(directory, "package")
    run!("node", scripts.join("create-package/index.ts").to_s,
      "--root", checkout, "--screenshots", screenshots, "--output", output, environment:)

    zip_path = File.join(directory, "package.zip")
    Zip::File.open(zip_path, create: true) do |archive|
      Dir.glob(File.join(output, "**/*"), File::FNM_DOTMATCH).sort.each do |file|
        next if File.directory?(file)

        archive.add(Pathname(file).relative_path_from(Pathname(output)).to_s, file)
      end
    end
    zip_path
  end

  # Runs only fixed executables with bounded error output, never a shell.
  def run!(*arguments, chdir: nil, environment: {})
    options = chdir ? { chdir: } : {}
    options[:unsetenv_others] = true if environment.any?
    output = error = nil
    status = nil
    Open3.popen3(environment, *arguments, **options, pgroup: true) do |input, stdout, stderr, wait|
      input.close
      output_thread = Thread.new { last_output(stdout) }
      error_thread = Thread.new { last_output(stderr) }
      begin
        status, output, error = Timeout.timeout(15.minutes) do
          [ wait.value, output_thread.value, error_thread.value ]
        end
      ensure
        if status.nil?
          begin
            Process.kill("KILL", -wait.pid)
          rescue Errno::ESRCH
            nil
          end
        end
        output_thread.kill if output_thread.alive?
        error_thread.kill if error_thread.alive?
      end
    end
    return if status.success?

    if arguments.first == "npm" && [ output, error ].any? { _1.to_s.include?("ENOTCACHED") }
      raise LocalDevelopment::Error,
        "npm needs a package missing from the local cache. Install dependencies while online once, then refresh."
    end

    raise LocalDevelopment::Error, "#{arguments.first} exited #{status.exitstatus}: " \
      "#{(error.presence || output).to_s.strip.last(700)}"
  end

  # Retains only the useful end of build logs without loading unlimited output.
  def last_output(stream)
    text = +""
    while (chunk = stream.read(8192))
      text << chunk
      text = text.byteslice(-1_024, 1_024) if text.bytesize > 1_024
    end
    text.scrub
  end
end

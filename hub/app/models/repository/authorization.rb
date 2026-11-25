# Resolves the user's effective access to one installed repository.
class Repository::Authorization < ActiveRecord::AssociatedObject
  CACHE_TTL = 1.minute
  PERMISSION_LEVELS = { "none" => 0, "read" => 1, "write" => 2, "admin" => 3 }.freeze
  NORMALIZED_PERMISSIONS = {
    "pull" => "read", "read" => "read", "triage" => "read",
    "push" => "write", "write" => "write", "maintain" => "write",
    "admin" => "admin"
  }.freeze

  attr_reader :share_link_creation_proof

  # Reports whether the user currently meets the requested permission level.
  def authorized?(
    user, minimum: :read, fresh: false, configuration: GithubAppConfiguration.current,
    cache: Rails.cache
  )
    permission = permission_for(user, fresh:, configuration:, cache:)
    sufficient?(permission, minimum:)
  end

  # Reads local grants on every decision, including when a GitHub result is cached.
  def permission_for(
    user, fresh: false, configuration: GithubAppConfiguration.current,
    cache: Rails.cache, payload: nil
  )
    return "none" if record.installation_state != "active" || user.nil?
    return local_permission(user) if LocalDevelopment.enabled?
    return "none" if record.local? || (user.is_a?(User) && user.local?)

    account = registered_user(user)
    if fresh
      @share_link_creation_proof = account && ShareLinkCreatorRevocation.proof_for(record, account)
    end
    return membership_role(account) if account&.external?

    return "none" unless user.github_id

    version = account&.current_membership_version unless fresh
    role = membership_role(account)
    github_permission = if fresh
      fetch_permission(user, configuration, payload: nil, account:, role:)
    else
      cache.fetch(cache_key(user, account, version), expires_in: CACHE_TTL) do
        fetch_permission(user, configuration, payload:, account:, role:)
      end
    end
    [ github_permission, role ].max_by { PERMISSION_LEVELS.fetch(_1) }
  rescue GithubClient::Error
    raise if role.nil? || role == "none"

    role
  end

  # Avoids fetching selector permissions that are still cached.
  def cached_permission(user, cache: Rails.cache, version: user.current_membership_version)
    cache.read(cache_key(user, user, version))
  end

  # Reports whether one normalized permission meets the required level.
  def sufficient?(permission, minimum:)
    PERMISSION_LEVELS.fetch(permission.to_s, 0) >= PERMISSION_LEVELS.fetch(minimum.to_s)
  end

  private

  def local_permission(user)
    return "none" unless user.is_a?(User) && user.persisted? && record.local?
    return "none" unless LocalDevelopment.repository_available?(record.local_path, identity: record.local_identity)
    return user.local? ? "admin" : "none" unless LocalDevelopment.unified_auth?

    user.local? ? "none" : membership_role(user)
  end

  def membership_role(account)
    return "none" unless account&.persisted?

    RepositoryMembership.where(repository: record, user: account).pick(:role) || "none"
  end

  # Reads effective permission and verifies GitHub returned the expected user.
  def fetch_permission(user, configuration, payload:, account:, role:)
    return "none" if configuration.nil? || configuration.installation_state != "active"

    raise payload if payload.is_a?(GithubClient::Error)

    payload ||= configuration.github_client.repositories.permission \
      record,
      user,
      token: configuration.tokens.installation
    raise GithubClient::InvalidResponse, "GitHub returned an invalid repository permission" if !payload.is_a?(Hash)

    profile = payload.fetch("user")
    return "none" if profile.nil?
    raise GithubClient::InvalidResponse, "GitHub returned an invalid permission identity" if !profile.is_a?(Hash)

    returned_id = profile.fetch("id")
    return "none" if !returned_id.is_a?(Integer) || returned_id != user.github_id

    permission = payload.fetch("permission")
    if permission == "none"
      ShareLinkCreatorRevocation.confirm_loss!(repository: record, user: account) if account && role == "none"
      return "none"
    end

    NORMALIZED_PERMISSIONS.fetch(permission) do
      raise GithubClient::InvalidResponse, "GitHub returned an unknown repository permission"
    end
  rescue GithubClient::NotFound
    "none"
  rescue KeyError, TypeError
    raise \
      GithubClient::InvalidResponse,
      "GitHub returned an incomplete repository permission"
  end

  # Resolves permission identities to saved creators before revoking their links.
  def registered_user(identity)
    return identity if identity.is_a?(User) && identity.persisted?

    User.find_by(github_id: identity.github_id) if identity.github_id
  end

  # Separates cached permission by durable identities and repository state.
  def cache_key(user, account, version)
    [ "repository-permission", record.cache_key_with_version, account&.id || "github-#{user.github_id}", version ]
  end
end

# Manages admission independently of repository content access.
class AuthAllowlistEntriesController < SuperglueController
  include ManagesAccess

  # @route GET /auth_allowlist_entries (auth_allowlist_entries)
  def index
    @entries = AuthAllowlistEntry.order(:email)
    if LocalDevelopment.enabled? && LocalDevelopment.unified_auth?
      Repository::LocalDiscovery.register_repositories!(on_error: Repository::LocalDiscovery.method(:report_error))
    end
    @managed_repositories = workspace_repositories
  end

  # @route POST /auth_allowlist_entries (auth_allowlist_entries)
  def create
    email = params.expect(:email).to_s.strip
    return reject_change(:invalid) if email.bytesize > 254

    name = params[:display_name]
    return reject_change(:invalid) unless name.nil? || name.is_a?(String)

    entry = AuthAllowlistEntry.create!(email:, display_name: name, hub_admin: params[:hub_admin] == "1", added_by: Current.user)
    user = User.find_by(identity_kind: "external", email: entry.email)
    if entry.hub_admin? && user && !user.hub_admin?
      user.change_hub_admin!(actor: Current.user, browser_session: Current.session, operation: "designate")
    end
    changed(allowlist_entry_id: entry.id)
  end

  # @route PATCH /auth_allowlist_entries/:id (auth_allowlist_entry)
  # @route PUT /auth_allowlist_entries/:id (auth_allowlist_entry)
  def update
    entry = AuthAllowlistEntry.find(params[:id])
    return reject_change(:invalid) unless params[:display_name].is_a?(String)

    entry.update!(display_name: params[:display_name])
    changed(allowlist_entry_id: entry.id)
  end

  # @route DELETE /auth_allowlist_entries/:id (auth_allowlist_entry)
  def destroy
    entry = AuthAllowlistEntry.find(params[:id])
    user = User.find_by(identity_kind: "external", email: entry.email)
    if user&.hub_admin?
      user.change_hub_admin!(actor: Current.user, browser_session: Current.session, operation: "revoke")
    end
    if user
      user.repository_memberships.find_each do |membership|
        membership.destroy!
        SecurityAuditEvent.record!(action: "repository_membership.destroy", outcome: "succeeded",
          repository: membership.repository, context: Current.security_audit_context.merge(target_user_id: user.id))
      end
      user.sessions.delete_all
      CanvasPairing.where(user:).delete_all
      CanvasGrant.where(user:, revoked_at: nil).update_all(revoked_at: Time.current)
    end
    EmailLoginChallenge.pending.where(email: entry.email).update_all(consumed_at: Time.current)
    entry.destroy!
    changed(allowlist_entry_id: entry.id)
  rescue User::AdminRoleChangeDenied => error
    raise unless error.reason == :last_admin

    reject_change(:last_admin)
  end

  private

  def authorize_access_management
    head :forbidden unless User.hub_admins.exists?(id: Current.user.id)
  end

  def management_path
    auth_allowlist_entries_path
  end

  def security_audit_action
    "allowlist.#{action_name}" unless action_name == "index"
  end
end

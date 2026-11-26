# Repository administrators may change only the grants in the selected repository.
class RepositoryMembershipsController < SuperglueController
  include ManagesAccess
  rescue_from GithubClient::Error, with: -> { head :service_unavailable }

  # @route GET /repositories/:repository_github_id/memberships (repository_memberships)
  def index
    @memberships = @repository.repository_memberships.includes(:user, :auth_allowlist_entry).order(:id)
  end

  # @route POST /repositories/:repository_github_id/memberships (repository_memberships)
  def create
    recipient = params.expect(:recipient).to_s.strip
    return reject_change(:unknown_recipient) if recipient.bytesize > 254
    if recipient.match?(/\A[1-9]\d{0,17}\z/)
      user = User.non_local.find_by(id: recipient)
      entry = AuthAllowlistEntry.find_by(email: user.email) if user&.external?
    else
      entry = AuthAllowlistEntry.find_by(email: recipient)
      user = User.non_local.find_by(email: recipient)
    end
    return reject_change(:unknown_recipient) if user&.external? && entry.nil?
    return reject_change(:unknown_recipient) unless user || entry

    membership = @repository.repository_memberships.create!(user:, auth_allowlist_entry: user ? nil : entry,
      role: params.expect(:role), granted_by: Current.user)
    changed(membership.audit_context)
  end

  # @route PATCH /repositories/:repository_github_id/memberships/:id (repository_membership)
  # @route PUT /repositories/:repository_github_id/memberships/:id (repository_membership)
  def update
    membership = @repository.repository_memberships.find(params[:id])
    membership.update!(role: params.expect(:role), granted_by: Current.user)
    changed(membership.audit_context)
  end

  # @route DELETE /repositories/:repository_github_id/memberships/:id (repository_membership)
  def destroy
    membership = @repository.repository_memberships.find(params[:id])
    membership.destroy!
    changed(membership.audit_context)
  end

  private

  def authorize_access_management
    @repository = Repository.find_by_route_id!(params[:repository_github_id])
    return head :not_found if Current.user.local?
    return if Current.user.reload.hub_admin?
    return if @repository.authorization.authorized?(Current.user, minimum: :admin, fresh: true)

    head :not_found
  end

  def management_path
    repository_memberships_path(@repository.route_id)
  end

  def security_audit_action
    "repository_membership.#{action_name}" unless action_name == "index"
  end
end

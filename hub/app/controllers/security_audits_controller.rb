# Gives enrolled operators deployment records, never repository-content permission.
class SecurityAuditsController < SuperglueController
  include HasSecurityAuditPage

  # @route GET /security_audit (security_audit)
  def show
    hub_admin = User.hub_admins.exists?(id: Current.user.id)
    return head :not_found if !hub_admin

    load_audit_scopes
    load_audit_events(SecurityAuditEvent.global.retained, path: security_audit_path)
    record_security_audit(outcome: "succeeded")
  end
end

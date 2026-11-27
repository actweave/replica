# Keep the authorization decision, mutation and audit event in one write transaction.
module ManagesAccess
  extend ActiveSupport::Concern

  included do
    before_action :authorize_access_management, only: :index
    around_action :change_access, except: :index
  end

  private

  def change_access
    ApplicationRecord.transaction do
      authorize_access_management
      next if performed?
      next unless enforce_security_rate_limit(:hub_admin)

      unless FreshAuthorization.fresh?(Current.session)
        request_new_sign_in(management_path)
        next
      end

      yield
    end
  rescue ActiveRecord::RecordInvalid => error
    raise if error.record.is_a?(SecurityAuditEvent)

    if error.record.is_a?(AuthAllowlistEntry) && error.record.errors.include?(:display_name)
      reject_change(:invalid_display_name)
    else
      reject_change(:invalid)
    end
  rescue ActiveRecord::RecordNotUnique
    reject_change(:invalid)
  end

  def changed(context)
    record_security_audit(outcome: "succeeded", context:)
    redirect_to management_path, notice: t("access_management.saved"), status: :see_other
  end

  def reject_change(reason)
    record_security_audit(outcome: "denied")
    redirect_to management_path, alert: t("access_management.#{reason}"), status: :see_other
  end
end

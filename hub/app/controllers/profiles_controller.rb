# Updates the public label of the signed-in external reviewer.
class ProfilesController < ApplicationController
  # @route PATCH /profile (profile)
  # @route PUT /profile (profile)
  def update
    return head :forbidden unless Current.user.external?

    name = params[:name].strip if params[:name].is_a?(String)
    if name.present? && DisplayName.valid?(name)
      User.transaction do
        Current.user.update!(name:)
        record_security_audit(outcome: "succeeded")
      end
      redirect_back_or_to repositories_path, allow_other_host: false, notice: t("profile.saved"), status: :see_other
    else
      record_security_audit(outcome: "denied")
      redirect_back_or_to repositories_path, allow_other_host: false, alert: t("profile.invalid"), status: :see_other
    end
  end

  private

  def security_audit_action
    "profile.update"
  end
end

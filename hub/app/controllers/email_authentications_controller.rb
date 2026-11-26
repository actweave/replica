# Admits a browser after proof of control of an allowlisted mailbox.
class EmailAuthenticationsController < ApplicationController
  allow_unauthenticated_access
  before_action :prepare_email_authentication

  # @route POST /auth/email/challenges (email_login_challenges)
  def create
    requested = EmailLoginChallenge.request!(email: @email, request_ip: trusted_request_ip)
    record_security_audit(outcome: requested ? "succeeded" : "denied")
    flash[:email_login] = @email
    redirect_to root_path, notice: t("email_login.sent"), status: :see_other
  end

  # @route POST /auth/email/verify (verify_email_login)
  def verify
    destination = nil
    verified = EmailLoginChallenge.verify(email: @email, code: params[:code].to_s) do |user|
      destination = authentication_return_to
      start_new_session_for(user, fresh_authorized_at: Time.current)
      show_welcome = user.consume_welcome_sign_in!
      destination ||= if show_welcome
        welcome_path
      elsif user.hub_admin? && user.repository_memberships.empty?
        hub_admins_path
      else
        repositories_path
      end
      record_security_audit(outcome: "succeeded", actor: user)
    end
    return redirect_to destination, status: :see_other if verified

    record_security_audit(outcome: "denied")
    flash[:email_login] = @email
    redirect_to root_path, alert: t("email_login.invalid"), status: :see_other
  end

  private

  def prepare_email_authentication
    response.headers["Cache-Control"] = "private, no-store"
    return head :not_found unless EmailLoginChallenge.enabled?

    value = params[:email]
    @email = value.is_a?(String) && value.bytesize <= 254 ? value.strip.downcase : ""
    feature = action_name == "create" ? :email_request : :email_verify
    return unless enforce_security_rate_limit(:"#{feature}_ip", identity: trusted_request_ip)

    enforce_security_rate_limit(feature, identity: Digest::SHA256.hexdigest(@email))
  end

  def security_audit_action
    action_name == "create" ? "email_login.request" : "email_login.verify"
  end
end

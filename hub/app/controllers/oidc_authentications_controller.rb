# Starts a browser-bound OIDC flow and admits a verified external identity.
class OidcAuthenticationsController < ApplicationController
  allow_unauthenticated_access
  before_action :prepare_provider
  before_action -> { enforce_security_rate_limit(:oauth_initiation, identity: trusted_request_ip) }, only: :create
  before_action -> { enforce_security_rate_limit(:oauth_callback, identity: trusted_request_ip) }, only: :callback
  rescue_from OidcProvider::InvalidResponse, SessionRevocation::Superseded, with: :denied

  # @route POST /auth/oidc/:provider (oidc_authentication)
  def create
    flow = {
      state: SecureRandom.urlsafe_base64(32), nonce: SecureRandom.urlsafe_base64(32), verifier: SecureRandom.urlsafe_base64(48),
      configuration: configuration_digest, expires_at: 10.minutes.from_now.to_i, generation: SessionRevocation.current.generation
    }
    uri = @provider.client.authorization_url(flow, redirect_uri)
    session[:oidc_flow] = flow
    response.location = uri
    head :see_other
  end

  # @route GET /auth/oidc/:provider/callback (oidc_callback)
  def callback
    flow = session.delete(:oidc_flow)
    return denied unless flow && flow["configuration"] == configuration_digest && flow["expires_at"] > Time.current.to_i
    return denied unless params[:state].is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(flow["state"], params[:state])
    return denied unless params[:code].is_a?(String) && params[:code].present? && !params.key?(:error)

    claims = @provider.client.verified_claims(code: params[:code], verifier: flow.fetch("verifier"), redirect_uri:, nonce: flow.fetch("nonce"))
    destination = SessionRevocation.with_generation!(flow.fetch("generation")) do
      entry = AuthAllowlistEntry.find_by(email: claims.fetch("email"))
      user = entry&.admit_verified_email!(provider: "oidc:#{@provider.slug}", issuer: @provider.issuer, subject: claims.fetch("sub"),
        name: claims["name"], avatar_url: claims["picture"])
      next unless user

      path = establish_external_session(user, generation: flow.fetch("generation"))
      record_security_audit(outcome: "succeeded", actor: user)
      path
    end
    return denied unless destination

    redirect_to destination, status: :see_other
  end

  private

  def prepare_provider
    response.headers["Cache-Control"] = "private, no-store"
    @provider = OidcProvider.enabled[params[:provider]]
    head :not_found unless @provider
  end

  def configuration_digest
    Digest::SHA256.hexdigest([ @provider.slug, @provider.issuer, @provider.client_id ].to_json)
  end

  def redirect_uri
    Rails.configuration.x.hub_origin.delete_suffix("/") + oidc_callback_path(@provider.slug)
  end

  def denied
    record_security_audit(outcome: "denied")
    redirect_to root_path, alert: t("oidc_login.failure"), status: :see_other
  end

  def security_audit_action
    "oidc_login.#{action_name}"
  end
end

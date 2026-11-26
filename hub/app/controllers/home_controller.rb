# Renders the public application entry point.
class HomeController < SuperglueController
  allow_unauthenticated_access
  content_security_policy do |policy|
    @oidc_providers = OidcProvider.enabled.values.filter_map do |provider|
      [ provider, provider.client.authorization_endpoint.origin ]
    rescue OidcProvider::InvalidResponse
      nil
    end.to_h
    HubContentSecurityPolicy.login_form_action(policy, @oidc_providers.values)
  end

  # @route GET / (root)
  def index
    resume_session
    if authenticated?
      flash.keep(:notice)
      redirect_to repositories_path
    end
  end
end

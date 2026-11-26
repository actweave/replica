# Renders the public application entry point.
class HomeController < SuperglueController
  allow_unauthenticated_access
  content_security_policy do |policy|
    HubContentSecurityPolicy.login_form_action(policy)
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

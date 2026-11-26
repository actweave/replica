require "test_helper"

class OidcAuthenticationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ISSUER = "https://identity.example.com/tenant"
  LOGIN = "https://login.example.com/authorize"
  TOKEN = "https://identity.example.com/token"
  JWKS = "https://identity.example.com/keys"

  setup do
    @previous_providers = Rails.configuration.x.oidc_providers
    @previous_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @secret = SecureRandom.hex
    config = { slug: "example", display_name: "Example SSO", issuer: ISSUER, client_id: "example-client",
      client_secret: @secret, scopes: "openid email profile" }
    Rails.configuration.x.oidc_providers = OidcProvider.parse([ config ].to_json)
    @discovery = stub_request(:get, "#{ISSUER}/.well-known/openid-configuration").to_return(
      body: { issuer: ISSUER, authorization_endpoint: LOGIN, token_endpoint: TOKEN, jwks_uri: JWKS }.to_json)
    @entry = AuthAllowlistEntry.create!(email: "reader@example.com")
    @signer = OpenSSL::PKey::RSA.generate(2048)
    @jwk = JWT::JWK.new(@signer)
    @keys = stub_request(:get, JWKS).to_return { { body: { keys: [ @jwk.export ] }.to_json } }
    @overrides = {}
    @exchange = stub_request(:post, TOKEN).with(basic_auth: [ "example-client", @secret ]).to_return do |request|
      form = URI.decode_www_form(request.body).to_h
      assert_equal "authorization_code", form["grant_type"]
      assert_equal @authorization.fetch("redirect_uri"), form["redirect_uri"]
      digest = Base64.urlsafe_encode64(Digest::SHA256.digest(form.fetch("code_verifier")), padding: false)
      if digest == @expected_challenge
        claims = { iss: ISSUER, aud: "example-client", exp: 2.minutes.from_now.to_i, iat: Time.current.to_i,
          nonce: @authorization.fetch("nonce"), sub: "subject-1", email: " Reader@example.com ", email_verified: true }
        algorithm = @signer.is_a?(OpenSSL::PKey::EC) ? "ES256" : "RS256"
        token = JWT.encode(claims.merge(@overrides), @signer, algorithm, kid: @jwk.kid)
        { body: { id_token: token }.to_json }
      else
        { status: 400, body: { error: "invalid_grant" }.to_json }
      end
    end
  end

  teardown do
    Rails.configuration.x.oidc_providers = @previous_providers
    Rails.cache = @previous_cache
  end

  test "home exposes the login action and permits its discovered origin" do
    get root_path, headers: { "Accept" => "application/json" }
    assert_response :success
    action = response.parsed_body.fetch("data").fetch("oidcProviders").sole
    assert_equal "/auth/oidc/example", action.fetch("path")
    assert_includes action.fetch("label"), "Example SSO"
    assert_not_includes response.body, @secret
    assert_includes response.headers.fetch("Content-Security-Policy")[/form-action [^;]+/].split, URI(LOGIN).origin
  end

  test "verified code flow reuses the email account and handles a rotating EC key" do
    user = sign_in_by_email
    delete session_path
    grant = RepositoryMembership.create!(repository: repositories.create, user:, role: "read")
    get repositories_path
    begin_login
    assert_no_difference("User.count") { finish_login }
    assert_redirected_to repositories_path
    assert_equal user, Session.sole.user
    assert_equal user, grant.reload.user
    assert_equal %w[email oidc:example], user.user_identities.order(:provider).pluck(:provider)
    assert_equal ISSUER, user.user_identities.find_by!(provider: "oidc:example").issuer
    delete session_path
    @signer = OpenSSL::PKey::EC.generate("prime256v1")
    @jwk = JWT::JWK.new(@signer)
    begin_login
    assert_no_difference("UserIdentity.count") { finish_login }
    assert_equal user, Session.sole.user
    assert_requested @discovery, times: 1
    assert_requested @keys, times: 2
    assert_equal 2, SecurityAuditEvent.where(action: "oidc_login.callback", outcome: "succeeded", user:).count
  end

  test "state mismatch consumes the flow without sending the code" do
    begin_login
    assert_no_difference("Session.count") do
      finish_login(state: SecureRandom.hex)
      finish_login
    end
    assert_not_requested @exchange
  end

  test "an expired flow cannot exchange a code" do
    begin_login
    travel 11.minutes do
      finish_login
      assert_redirected_to root_path
    end
    assert_not_requested @exchange
  end

  test "ending all sessions invalidates a pending sign-in before account admission" do
    begin_login
    admin = users.create(hub_admin: true)
    SessionRevocation.end_all!(actor: admin, browser_session: admin.sessions.create!(fresh_authorized_at: Time.current))
    assert_no_difference([ "Session.count", "UserIdentity.count" ]) { finish_login }
    assert_redirected_to root_path
  end

  test "a code bound to a different verifier is denied" do
    begin_login
    @expected_challenge = SecureRandom.hex
    assert_no_difference("Session.count") { finish_login }
    assert_redirected_to root_path
    assert_requested @exchange
  end

  test "a signature from another key is denied" do
    begin_login
    @signer = OpenSSL::PKey::RSA.generate(2048)
    assert_no_difference("Session.count") { finish_login }
    assert_redirected_to root_path
  end

  test "invalid claims and unlisted mailboxes cannot establish an identity" do
    [
      { iss: "https://other.example.com" }, { aud: "another-client" }, { azp: "another-client" },
      { exp: 1.minute.ago.to_i }, { iat: 1.minute.from_now.to_i }, { nonce: SecureRandom.hex },
      { email_verified: false }, { email_verified: "true" }, { email: "unknown@example.com" }
    ].each do |changes|
      @overrides = changes
      begin_login
      assert_no_difference([ "Session.count", "UserIdentity.count" ]) { finish_login }
      assert_redirected_to root_path
      assert_equal "denied", SecurityAuditEvent.last.outcome
    end
  end

  test "an existing subject cannot move accounts or cross an issuer change" do
    begin_login
    finish_login
    user = Session.sole.user
    delete session_path
    other = AuthAllowlistEntry.create!(email: "other@example.com")
    @overrides = { email: other.email }
    begin_login
    assert_no_difference("Session.count") { finish_login }
    assert_equal user, UserIdentity.sole.user
    UserIdentity.sole.update!(issuer: "https://previous.example.com")
    @overrides.clear
    begin_login
    assert_no_difference("Session.count") { finish_login }
    assert_redirected_to root_path
  end

  private

  def sign_in_by_email
    settings = { "REPLICA_AUTH_EMAIL_ENABLED" => "true", "RESEND_API_KEY" => SecureRandom.hex,
      "RESEND_FROM_EMAIL" => "hub@example.com", "RESEND_API_BASE_URL" => "https://mail.example.invalid" }
    original = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    code = nil
    stub_request(:post, "https://mail.example.invalid/emails").to_return do |request|
      code = JSON.parse(request.body).fetch("text")[/\b[0-9]{6}\b/]
      { status: 200 }
    end
    perform_enqueued_jobs { post email_login_challenges_path, params: { email: @entry.email } }
    assert code
    post verify_email_login_path, params: { email: @entry.email, code: }
    Session.sole.user
  ensure
    settings.each_key { ENV.delete(_1) }
    ENV.update(original)
  end

  def begin_login
    post oidc_authentication_path("example")
    assert_response :see_other
    uri = URI(response.location)
    assert_equal URI(LOGIN).origin, uri.origin
    @authorization = URI.decode_www_form(uri.query).to_h
    assert_equal "code", @authorization.fetch("response_type")
    assert_equal "S256", @authorization.fetch("code_challenge_method")
    @expected_challenge = @authorization.fetch("code_challenge")
  end

  def finish_login(state: @authorization.fetch("state"))
    get oidc_callback_path("example"), params: { state:, code: SecureRandom.hex }
  end
end

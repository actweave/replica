require "test_helper"
require_relative "../support/security_rate_limit_store"

class EmailAuthenticationsTest < ActionDispatch::IntegrationTest
  include SecurityRateLimitStore

  setup do
    settings = {
      "REPLICA_AUTH_MODE" => "unified", "RESEND_API_KEY" => SecureRandom.hex,
      "RESEND_FROM_EMAIL" => "hub@example.com", "RESEND_API_BASE_URL" => "https://mail.example.invalid"
    }
    @previous_settings = ENV.to_h.slice(*settings.keys)
    @setting_keys = settings.keys
    ENV.update(settings)
    use_security_rate_limit_store
    @entry = AuthAllowlistEntry.create!(email: "reader@example.com", hub_admin: true)
    @delivery = stub_request(:post, "https://mail.example.invalid/emails")
      .with(headers: { "Authorization" => "Bearer #{ENV.fetch("RESEND_API_KEY")}" })
      .to_return do |request|
        mail = JSON.parse(request.body)
        assert_equal [ @entry.email ], mail.fetch("to")
        @code = mail.fetch("text")[/\b[0-9]{6}\b/]
        assert @code
        { status: 200, body: "{}" }
      end
  end

  teardown do
    @setting_keys.each { ENV.delete(_1) }
    ENV.update(@previous_settings)
    restore_security_rate_limit_store
  end

  test "verified sign-in admits one external account, rotates sessions and consumes each code once" do
    get repositories_path
    request_code
    follow_redirect! headers: { "Accept" => "application/json" }
    data = response.parsed_body.fetch("data")
    assert_equal @entry.email, data.fetch("emailLogin").fetch("email")
    assert_nil data["signInPath"]
    challenge = EmailLoginChallenge.sole
    assert_not_equal @code, challenge.code_digest
    assert_difference("Session.count") { verify(@code) }
    assert_redirected_to repositories_path
    get root_path
    assert_redirected_to repositories_path
    user = User.find_by!(email: @entry.email)
    assert user.external?
    assert user.hub_admin?
    assert user.user_identities.sole.email_verified?
    assert_equal user, SecurityAuditEvent.where(action: "email_login.verify", outcome: "succeeded").sole.user
    delete session_path
    assert_no_difference("Session.count") { verify(@code) }
    request_code
    assert_no_difference([ "User.count", "UserIdentity.count" ]) { verify(@code) }
    assert_equal user, Session.sole.user
  end

  test "a conflicting GitHub account leaves the verified code available" do
    users.create(email: @entry.email)
    request_code
    assert_no_difference("Session.count") { verify(@code) }
    assert_nil EmailLoginChallenge.sole.consumed_at
    assert_empty UserIdentity.where(provider: "email", subject: @entry.email)
  end

  test "five wrong attempts lock the challenge including against the correct code" do
    request_code
    wrong = @code == "000000" ? "000001" : "000000"
    assert_no_difference("Session.count") do
      5.times { verify(wrong) }
      verify(@code)
    end
    assert_equal 5, EmailLoginChallenge.sole.attempts
  end

  test "replacement, expiry and removing admission each prevent use of an issued code" do
    request_code
    previous = @code
    request_code
    assert EmailLoginChallenge.first.consumed_at
    assert_no_difference("Session.count") { verify(previous) } if previous != @code
    travel_to EmailLoginChallenge.last.expires_at.ceil do
      assert_no_difference("Session.count") { verify(@code) }
    end
    @entry.destroy!
    assert_no_difference("Session.count") { verify(@code) }
  end

  test "unknown email gets identical feedback and cannot receive a code or sign in" do
    request_code
    accepted = [ response.status, response.location, flash[:notice] ]
    assert_no_difference("EmailLoginChallenge.count") { request_code("unknown@example.com") }
    assert_equal accepted, [ response.status, response.location, flash[:notice] ]
    assert_requested @delivery, times: 1
    assert_no_difference("Session.count") { verify(@code, email: "unknown@example.com") }
  end

  test "the request budget applies to normalized email and trusted IP independently" do
    5.times { request_code("unknown@example.com") }
    post email_login_challenges_path, params: { email: " UNKNOWN@example.com " }, as: :json
    assert_security_throttle(600)
    24.times { |n| request_code("unknown#{n}@example.com") }
    post email_login_challenges_path, params: { email: "fresh@example.com" }, as: :json
    assert_security_throttle(600)
  end

  test "ending all sessions invalidates outstanding email proofs" do
    request_code
    admin = users.create(hub_admin: true)
    SessionRevocation.end_all!(actor: admin, browser_session: admin.sessions.create!(fresh_authorized_at: Time.current))
    assert_no_difference("Session.count") { verify(@code) }
  end

  test "unified local mode restores external sessions and disables one-click local sessions" do
    original = LocalDevelopment.method(:enabled?)
    LocalDevelopment.define_singleton_method(:enabled?) { true }
    local = User.local_developer!.sessions.create!
    assert_not local.resumable?
    post local_authentication_path
    assert_response :not_found
    request_code
    verify(@code)
    get root_path
    assert_redirected_to repositories_path
  ensure
    LocalDevelopment.define_singleton_method(:enabled?, original)
  end

  private

  def request_code(email = " Reader@example.com ")
    perform_enqueued_jobs do
      post email_login_challenges_path, params: { email: }
    end
    assert_redirected_to root_path
  end

  def verify(code, email: @entry.email)
    post verify_email_login_path, params: { email:, code: }
  end
end

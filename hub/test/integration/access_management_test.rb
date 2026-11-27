require "test_helper"

class AccessManagementTest < ActionDispatch::IntegrationTest
  setup do
    @previous_mode = ENV["REPLICA_AUTH_MODE"]
    ENV["REPLICA_AUTH_MODE"] = "unified"
    @admin = AuthAllowlistEntry.create!(email: "admin@example.com", hub_admin: true)
    @a = repositories.create
    @b = repositories.create(github_id: 2002, name_with_owner: "example/other")
    sign_in(self, @admin)
    @path = repository_memberships_path(@a.route_id)
  end

  teardown do
    ENV["REPLICA_AUTH_MODE"] = @previous_mode
  end

  test "grant before first sign-in, change and revoke access in a live browser" do
    get repository_path(@a.route_id)
    assert_response :not_found
    get auth_allowlist_entries_path, as: :json
    assert_response :success
    assert_includes response.parsed_body["data"]["repositories"].pluck("path"), @path

    submitted_email = " Reader@Example.COM "
    post auth_allowlist_entries_path, params: { email: submitted_email }
    entry = AuthAllowlistEntry.find_by!(email: "reader@example.com")
    post @path, params: { recipient: submitted_email, role: "read" }
    grant = @a.repository_memberships.find_by!(auth_allowlist_entry: entry)
    assert_nil User.find_by(email: entry.email)
    get @path, as: :json
    assert response.parsed_body["data"]["rows"].sole["pending"]
    reader = open_session
    sign_in(reader, entry)
    assert_equal User.find_by!(email: entry.email), grant.reload.user
    assert_nil grant.auth_allowlist_entry_id
    assert_equal "read", grant.role
    reader.get repository_path(@a.route_id), as: :json
    assert_equal [ @a.route_id.to_s ], reader.response.parsed_body["data"]["repositories"].pluck("id")
    reader.get repository_path(@b.route_id)
    assert_equal 404, reader.response.status
    reader.get @path
    assert_equal 404, reader.response.status
    reader.patch repository_membership_path(@a.route_id, RepositoryMembership.sole), params: { role: "admin" }
    assert_equal 404, reader.response.status
    assert_equal "read", RepositoryMembership.sole.role
    reader.get auth_allowlist_entries_path
    assert_equal 403, reader.response.status

    path = repository_membership_path(@a.route_id, grant)
    patch path, params: { role: "admin" }
    reader.get @path, as: :json
    assert_equal "admin", reader.response.parsed_body["data"]["rows"].sole["role"]
    reader.get repository_memberships_path(@b.route_id)
    assert_equal 404, reader.response.status
    other = users.create
    reader.post @path, params: { recipient: other.id.to_s, role: "write" }
    assert_equal "write", @a.repository_memberships.find_by!(user: other).role
    delete path
    reader.get repository_path(@a.route_id)
    assert_equal 404, reader.response.status
    reader.get repositories_path
    assert_equal 404, reader.response.status
    event = SecurityAuditEvent.where(action: "repository_membership.destroy").sole
    assert_equal @a, event.repository
    assert_equal grant.user_id, event.context["target_user_id"]
    assert_equal User.find_by!(email: @admin.email), event.user
  end

  test "allowlist names seed verified accounts and profile edits keep the public identity stable" do
    post auth_allowlist_entries_path, params: { email: "reader@example.com", display_name: "  Initial  " }
    entry = AuthAllowlistEntry.find_by!(email: "reader@example.com")
    assert_equal "Initial", entry.display_name
    patch auth_allowlist_entry_path(entry), params: { display_name: "  Jordan  ", hub_admin: "1" }
    assert_equal "Jordan", entry.reload.display_name
    assert_not entry.hub_admin?
    patch auth_allowlist_entry_path(entry), params: { display_name: "x" * 81 }
    assert_equal "Jordan", entry.reload.display_name

    post @path, params: { recipient: entry.email, role: "read" }
    reader = open_session
    sign_in(reader, entry)
    user = User.find_by!(email: entry.email)
    assert_equal "Jordan", user.name
    assert_match(/\Areviewer-[a-f0-9]+\z/, user.login)
    reader.patch profile_path, params: { name: "李" * 80 }
    reader.get repository_path(@a.route_id), as: :json
    identity = reader.response.parsed_body.fetch("data").fetch("currentUser")
    assert_equal "李" * 80, identity.fetch("name")
    assert_equal profile_path, identity.fetch("profile").fetch("path")
    assert_not_includes reader.response.body, entry.email
    [ "a" * 81, "<b>name</b>", entry.email, " " ].each do |name|
      reader.patch profile_path, params: { name: }
      assert_equal "李" * 80, user.reload.name
      assert_equal "denied", SecurityAuditEvent.where(action: "profile.update").last.outcome
    end
    reader.patch auth_allowlist_entry_path(entry), params: { display_name: "Other" }
    assert_equal 403, reader.response.status
    reader.delete session_path
    sign_in(reader, entry)
    assert_equal "李" * 80, user.reload.name
  end

  test "updating the profile requires the browser authenticity token" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    patch profile_path, params: { name: "Changed" }
    assert_response :unprocessable_entity
    assert_nil User.find_by!(email: @admin.email).name
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "a returning email administrator without grants lands in Hub administration" do
    delete session_path
    sign_in(self, @admin)
    assert_redirected_to hub_admins_path
    get repositories_path
    assert_response :not_found
  end

  test "last administrator is preserved and removing another administrator ends access" do
    delete auth_allowlist_entry_path(@admin)
    assert AuthAllowlistEntry.exists?(@admin.id)
    assert Session.exists?(user: User.find_by!(email: @admin.email))
    assert_equal "denied", SecurityAuditEvent.where(action: "allowlist.destroy").last.outcome

    post auth_allowlist_entries_path, params: { email: "second@example.com", hub_admin: "1" }
    second = AuthAllowlistEntry.find_by!(email: "second@example.com")
    browser = open_session
    sign_in(browser, second)
    browser.get auth_allowlist_entries_path, as: :json
    assert_equal 200, browser.response.status
    target = User.find_by!(email: second.email)
    post @path, params: { recipient: " Second@Example.COM ", role: "admin" }
    assert_equal "admin", @a.repository_memberships.find_by!(user: target).role
    delete auth_allowlist_entry_path(second)
    assert_empty @a.repository_memberships
    assert_not target.reload.hub_admin?
    browser.get auth_allowlist_entries_path
    assert_equal root_url, browser.response.location
    patch hub_admin_path(target), params: { operation: "designate", confirmed: "1" }
    assert_not target.reload.hub_admin?
    assert_equal "succeeded", SecurityAuditEvent.where(action: "allowlist.destroy").last.outcome
  end

  test "a removed external account cannot receive a grant by email or user ID" do
    entry = AuthAllowlistEntry.create!(email: "former@example.com")
    sign_in(open_session, entry)
    user = User.find_by!(email: entry.email)
    delete auth_allowlist_entry_path(entry)
    [ user.email, user.id.to_s ].each do |recipient|
      assert_no_difference("RepositoryMembership.count") { post @path, params: { recipient:, role: "read" } }
      assert_equal "denied", SecurityAuditEvent.where(action: "repository_membership.create").last.outcome
    end
  end

  test "stale external browser signs in again before manually submitting its change" do
    Session.sole.update!(fresh_authorized_at: 6.minutes.ago)
    sign_in(open_session, @admin)
    post auth_allowlist_entries_path, params: { email: "new@example.com" }
    assert_redirected_to root_path
    assert_equal "denied", SecurityAuditEvent.where(action: "allowlist.create").last.outcome
    sign_in(self, @admin)
    assert_redirected_to auth_allowlist_entries_path
    assert_not AuthAllowlistEntry.exists?(email: "new@example.com")
    post auth_allowlist_entries_path, params: { email: "new@example.com" }
    assert AuthAllowlistEntry.exists?(email: "new@example.com")
  end

  test "existing administrator controls accept fresh email proof after another sign-in" do
    target = users.create
    Session.sole.update!(fresh_authorized_at: 6.minutes.ago)
    form = { operation: "designate", confirmed: "1" }
    patch hub_admin_path(target), params: form
    assert_redirected_to root_path
    assert_not target.reload.hub_admin?
    sign_in(self, @admin)
    assert_redirected_to edit_hub_admin_path(target)
    patch hub_admin_path(target), params: form
    assert target.reload.hub_admin?
    assert_equal "succeeded", SecurityAuditEvent.where(action: "hub_admin.designate").last.outcome
  end

  private

  def sign_in(browser, entry)
    code = format("%06d", SecureRandom.random_number(1_000_000))
    challenge = EmailLoginChallenge.create!(email: entry.email, expires_at: 10.minutes.from_now)
    challenge.update!(code_digest: challenge.digest(code))
    browser.post verify_email_login_path, params: { email: entry.email, code: }
    assert_equal 303, browser.response.status
  end
end

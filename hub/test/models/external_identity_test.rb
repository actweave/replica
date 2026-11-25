require "test_helper"

class ExternalIdentityTest < ActiveSupport::TestCase
  test "external identities can share the database with exactly one local developer" do
    external = users.create(github_id: nil, identity_kind: "external", email: " Reader@Example.com ")
    other = users.create(github_id: nil, identity_kind: "external", email: "other@example.invalid")
    assert_equal "reader@example.com", external.email
    assert_not other.update(email: " READER@example.com ")
    assert_not external.local?

    original = LocalDevelopment.method(:enabled?)
    LocalDevelopment.define_singleton_method(:enabled?) { true }
    local = User.local_developer!
    assert local.local?
    assert_equal local, User.local_developer!
    assert_raises(ActiveRecord::RecordNotUnique) { local.dup.save! }
  ensure
    LocalDevelopment.define_singleton_method(:enabled?, original) if original
  end

  test "email subjects are canonical and OIDC subjects stay case sensitive" do
    user = users.create
    identity = user.user_identities.create!(provider: "email", subject: " Reader@Example.com ")
    assert_equal "reader@example.com", identity.subject
    assert_not user.user_identities.build(provider: "email", subject: "READER@example.com").valid?
    oidc = user.user_identities.create!(provider: "oidc:demo", subject: "CaseSensitive")
    assert_equal "CaseSensitive", oidc.subject
  end

  test "bootstrap applies overlapping environment grants once and preserves later revocations" do
    env = {
      "REPLICA_AUTH_ALLOWLIST_EMAILS" => " Reader@Example.com , ,admin@example.com ",
      "REPLICA_AUTH_BOOTSTRAP_ADMIN_EMAILS" => " ADMIN@example.com ,admin@example.com"
    }
    2.times { AuthAllowlistEntry.bootstrap!(env) }
    reader, admin = %w[reader@example.com admin@example.com].map { AuthAllowlistEntry.find_by!(email: _1) }
    assert_not reader.hub_admin?
    assert admin.hub_admin?
    assert_equal 2, AuthAllowlistEntry.count
    reader.destroy!
    admin.update!(hub_admin: false)
    AuthAllowlistEntry.bootstrap!(env)
    assert_equal [ admin ], AuthAllowlistEntry.all
    assert_not admin.reload.hub_admin?
  end

  test "external administrators can manage roles and count toward the last administrator guard" do
    actor = users.create(github_id: nil, identity_kind: "external", hub_admin: true)
    session = actor.sessions.create!(fresh_authorized_at: Time.current)
    github = users.create(hub_admin: true)
    entry = AuthAllowlistEntry.create!(email: "member@example.com")
    target = users.create(identity_kind: "external", github_id: nil, email: entry.email)
    target.change_hub_admin!(actor:, browser_session: session, operation: "designate")
    assert entry.reload.hub_admin?
    target.change_hub_admin!(actor:, browser_session: session, operation: "revoke")
    assert_not entry.reload.hub_admin?
    github.change_hub_admin!(actor:, browser_session: session, operation: "revoke")
    error = assert_raises(User::AdminRoleChangeDenied) do
      actor.change_hub_admin!(actor:, browser_session: session, operation: "revoke")
    end
    assert_equal :last_admin, error.reason
  end
end

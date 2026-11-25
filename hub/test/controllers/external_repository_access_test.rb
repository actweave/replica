require "test_helper"

class ExternalRepositoryAccessTest < ActionController::TestCase
  tests RepositoriesController

  test "an external administrator sees only granted repositories and loses access on revocation" do
    github_app_configurations.create_installed
    user = users.create(github_id: nil, identity_kind: "external", hub_admin: true)
    @request.session[:authenticated_session_id] = user.sessions.create!.id
    allowed = repositories.create
    other = repositories.create(github_id: 2002)
    grant = allowed.repository_memberships.create!(user:, role: "read")

    get :index
    assert_redirected_to repository_path(allowed.route_id)
    get :show, params: { github_id: other.route_id }
    assert_response :not_found
    post :poll, params: { github_id: allowed.route_id }
    assert_response :not_found

    grant.update!(role: "write")
    post :poll, params: { github_id: allowed.route_id }
    assert_response :accepted
    grant.destroy!
    get :index
    assert_response :not_found
    get :show, params: { github_id: allowed.route_id }
    assert_response :not_found
  end
end

require "test_helper"

class SelfHostedBuildsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_runner = ENV["REPLICA_BUILD_RUNNER"]
    ENV["REPLICA_BUILD_RUNNER"] = "self_hosted"
    @configuration = github_app_configurations.create_installed
  end

  teardown do
    ENV["REPLICA_BUILD_RUNNER"] = @previous_runner
  end

  test "authenticated pushes and authorized refresh request repository discovery without workflow setup" do
    payload = repository_payload(2001, "example/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in_to_hub
    repository = Repository.find_by!(github_id: 2001)
    get repository_path(repository.route_id), headers: { "Accept" => "application/json" }
    assert_response :success
    assert_nil response.parsed_body.fetch("data")["workflowInstallation"]
    assert_not_requested :get, %r{/contents/\.github/workflows/replica\.yml}

    assert_enqueued_with(job: GithubAppConfiguration::DiscoverBuildsJob, args: [ @configuration, repository ]) do
      post poll_repository_path(repository.route_id)
    end
    assert_response :accepted
    body = JSON.generate(installation: { id: 456 }, repository: { id: 2001 }, ref: "refs/heads/main", deleted: false)
    assert_enqueued_with(job: GithubAppConfiguration::DiscoverBuildsJob, args: [ @configuration, repository ]) do
      post github_webhooks_path, params: body, headers: {
        "Content-Type" => "application/json", "X-GitHub-Event" => "push", "X-GitHub-Delivery" => "push-1",
        "X-Hub-Signature-256" => "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, body)}"
      }
    end
    assert_response :accepted
  end
end

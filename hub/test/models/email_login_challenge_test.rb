require "test_helper"

class EmailLoginChallengeTest < ActiveSupport::TestCase
  test "a late job cannot deliver a superseded challenge and a failed delivery can be retried" do
    entry = AuthAllowlistEntry.create!(email: "reviewer@example.com")
    config = { "REPLICA_AUTH_EMAIL_ENABLED" => "true", "RESEND_API_KEY" => SecureRandom.hex,
      "RESEND_FROM_EMAIL" => "hub@example.com", "RESEND_API_BASE_URL" => "https://email.example.invalid" }
    original = ENV.to_h.slice(*config.keys)
    ENV.update(config)
    2.times { EmailLoginChallenge.request!(email: entry.email, request_ip: nil) }
    expired, current = EmailLoginChallenge.order(:id)
    delivery = stub_request(:post, "https://email.example.invalid/emails")
      .to_return({ status: 503 }, { status: 200 })
    expired.deliver!
    assert_not_requested delivery
    assert_raises(ResendClient::DeliveryError) { current.deliver! }
    current.deliver!
    current.deliver!
    assert_requested delivery, times: 2
    assert current.reload.code_digest.present?
  ensure
    config.each_key { ENV.delete(_1) }
    ENV.update(original)
  end
end

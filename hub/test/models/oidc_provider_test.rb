require "test_helper"

class OidcProviderTest < ActiveSupport::TestCase
  test "rejects ambiguous configuration without echoing client credentials" do
    secret = SecureRandom.hex
    config = { slug: "google", display_name: "Google", issuer: "https://accounts.example.com",
      client_id: "example-client", client_secret: secret, scopes: "openid email" }
    assert_empty OidcProvider.parse(nil)
    assert_equal %w[google second], OidcProvider.parse([ config, config.merge(slug: "second") ].to_json).keys
    [ secret, {}, [ config, config ], [ config.merge(slug: "../other") ], [ config.except(:client_id) ],
      [ config.merge(scopes: "openid") ], [ config.merge(issuer: "http://example.com") ] ].each do |input|
      error = assert_raises(OidcProvider::ConfigurationError) { OidcProvider.parse(input.is_a?(String) ? input : input.to_json) }
      assert_not_includes error.message, secret
    end
  end
end

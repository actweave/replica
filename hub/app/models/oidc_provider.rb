# Configuration for a trusted OpenID Connect issuer. Secrets stay server-side.
class OidcProvider
  class ConfigurationError < StandardError; end
  class InvalidResponse < StandardError; end

  attr_reader :slug, :display_name, :issuer, :client_id, :scopes

  # Reject invalid registry entries at boot without including secret values in errors.
  def self.parse(json)
    entries = json.blank? ? [] : JSON.parse(json)
    raise ConfigurationError, "REPLICA_OIDC_PROVIDERS_JSON must contain an array" unless entries.is_a?(Array)

    entries.each_with_index.each_with_object({}) do |(fields, index), providers|
      raise ConfigurationError, "entry #{index + 1} must be an object" unless fields.is_a?(Hash)

      provider = new(fields)
      raise ConfigurationError, "duplicate provider slug" if providers.key?(provider.slug)

      providers[provider.slug] = provider
    rescue ConfigurationError => error
      raise ConfigurationError, "REPLICA_OIDC_PROVIDERS_JSON entry #{index + 1}: #{error.message}"
    end
  rescue JSON::ParserError
    raise ConfigurationError, "REPLICA_OIDC_PROVIDERS_JSON must contain valid JSON", cause: nil
  end

  # Default local mode only accepts its local developer account.
  def self.enabled
    return {} if LocalDevelopment.enabled? && !LocalDevelopment.unified_auth?

    Rails.configuration.x.oidc_providers
  end

  def initialize(fields)
    %w[slug display_name issuer client_id client_secret scopes].each do |key|
      raise ConfigurationError, "#{key} must be a nonempty string" unless fields[key].is_a?(String) && fields[key].present?
    end
    @slug, @display_name, @issuer, @client_id, @client_secret, @scopes =
      fields.values_at("slug", "display_name", "issuer", "client_id", "client_secret", "scopes")
    raise ConfigurationError, "invalid slug" unless /\A[a-z0-9][a-z0-9_-]{0,63}\z/.match?(slug)
    raise ConfigurationError, "scopes must include openid and email" unless (%w[openid email] - scopes.split).empty?
    raise ConfigurationError, "issuer cannot include a query" if self.class.https_uri(issuer).query
  rescue InvalidResponse
    raise ConfigurationError, "issuer must be an absolute HTTPS URL without credentials or fragment"
  end

  # Both configured issuers and discovered endpoints must use TLS.
  def self.https_uri(value)
    uri = URI.parse(value) if value.is_a?(String)
    raise InvalidResponse unless uri.is_a?(URI::HTTPS) && uri.host.present? && !uri.userinfo && !uri.fragment

    uri
  rescue URI::InvalidURIError
    raise InvalidResponse
  end

  # Keep token exchange credentials out of the registry presentation API.
  def client
    OidcClient.new(self, @client_secret)
  end

  def inspect
    "#<OidcProvider #{slug}>"
  end
end

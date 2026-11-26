Rails.application.config.to_prepare do
  Rails.configuration.x.oidc_providers = OidcProvider.parse(ENV["REPLICA_OIDC_PROVIDERS_JSON"])
end

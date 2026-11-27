require "jwt"
require "net/http"

# Authorization code exchange with an issuer selected by the Hub operator.
class OidcClient
  InvalidResponse = OidcProvider::InvalidResponse

  def initialize(provider, secret)
    @provider = provider
    @secret = secret
  end

  # The login page also uses this endpoint to restrict form redirects.
  def authorization_endpoint
    OidcProvider.https_uri(metadata.fetch("authorization_endpoint"))
  end

  # Preserve any query fields published by the provider.
  def authorization_url(flow, redirect_uri)
    uri = authorization_endpoint
    params = URI.decode_www_form(uri.query.to_s).to_h.merge(
      "response_type" => "code", "client_id" => @provider.client_id, "redirect_uri" => redirect_uri,
      "scope" => @provider.scopes, "state" => flow.fetch(:state), "nonce" => flow.fetch(:nonce),
      "code_challenge_method" => "S256",
      "code_challenge" => Base64.urlsafe_encode64(Digest::SHA256.digest(flow.fetch(:verifier)), padding: false)
    )
    uri.query = URI.encode_www_form(params)
    uri.to_s
  end

  # Exchange only at the discovered endpoint, using a supported client authentication method.
  def verified_claims(code:, verifier:, redirect_uri:, nonce:)
    uri = OidcProvider.https_uri(metadata.fetch("token_endpoint"))
    request = Net::HTTP::Post.new(uri)
    form = { grant_type: "authorization_code", code:, redirect_uri:, code_verifier: verifier }
    methods = metadata.fetch("token_endpoint_auth_methods_supported", [ "client_secret_basic" ])
    if methods.include?("client_secret_basic")
      request.basic_auth(URI.encode_www_form_component(@provider.client_id), URI.encode_www_form_component(@secret))
    elsif methods.include?("client_secret_post")
      form.merge!(client_id: @provider.client_id, client_secret: @secret)
    else
      raise InvalidResponse
    end
    request.set_form_data(form)
    token = request_json(uri, request)["id_token"]
    raise InvalidResponse unless token.is_a?(String)

    OidcIdToken.verify(token, @provider, nonce:) { |refresh| signing_keys(refresh) }
  end

  private

  # Bind discovery to the exact issuer before caching endpoints.
  def metadata
    @metadata ||= Rails.cache.fetch([ "oidc-discovery", @provider.issuer ], expires_in: 1.hour) do |_key, options|
      uri = URI("#{@provider.issuer.delete_suffix("/")}/.well-known/openid-configuration")
      document = request_json(uri)
      raise InvalidResponse unless document["issuer"] == @provider.issuer
      %w[authorization_endpoint token_endpoint jwks_uri].each { OidcProvider.https_uri(document[_1]) }
      methods = document["token_endpoint_auth_methods_supported"]
      raise InvalidResponse if document.key?("token_endpoint_auth_methods_supported") && !methods.is_a?(Array)

      document
    rescue InvalidResponse
      options.expires_in = 1.minute
      nil
    end
    @metadata || raise(InvalidResponse)
  end

  # Bound trust in retired keys even when no new token triggers a refresh.
  def signing_keys(refresh)
    uri = OidcProvider.https_uri(metadata.fetch("jwks_uri"))
    Rails.cache.fetch([ "oidc-jwks", @provider.issuer, uri.to_s ], expires_in: 10.minutes, force: refresh) do
      keys = request_json(uri)["keys"]
      raise InvalidResponse unless keys.is_a?(Array) && keys.all?(Hash)

      keys
    end
  end

  # Redirects and unsuccessful exchanges never supply trusted metadata or tokens.
  def request_json(uri, request = Net::HTTP::Get.new(uri))
    http = HttpsClient.for(uri)
    request["Accept"] = "application/json"
    response = http.request(request)
    raise InvalidResponse unless response.is_a?(Net::HTTPSuccess)

    document = JSON.parse(response.body.to_s)
    raise InvalidResponse unless document.is_a?(Hash)

    document
  rescue JSON::ParserError, IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    raise InvalidResponse, cause: nil
  end
end

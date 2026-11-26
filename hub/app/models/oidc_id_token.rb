# Accepts only signed ID tokens for this client, issuer, and browser flow.
class OidcIdToken
  InvalidResponse = OidcProvider::InvalidResponse
  KEY_TYPES = { "RS256" => "RSA", "ES256" => "EC" }.freeze

  # Check the signature and registered claims before accepting a mailbox.
  def self.verify(token, provider, nonce:)
    encoded = JWT::EncodedToken.new(token)
    header = encoded.header
    raise InvalidResponse unless header.is_a?(Hash) && !header.key?("crit")
    alg = header["alg"]
    raise InvalidResponse unless KEY_TYPES.key?(alg)

    keys = matching_keys(yield(false), header)
    keys = matching_keys(yield(true), header) if keys.empty?
    raise InvalidResponse unless keys.one?

    # The JWT date validators expect values convertible to NumericDate.
    payload = encoded.unverified_payload
    raise InvalidResponse unless payload.is_a?(Hash) && payload["exp"].is_a?(Integer) && payload["iat"].is_a?(Integer)
    raise InvalidResponse if payload.key?("nbf") && !payload["nbf"].is_a?(Integer)

    key = JWT::JWK.import(keys.first).verify_key
    claims, = JWT.decode(token, key, true, algorithm: alg, iss: provider.issuer, verify_iss: true,
      aud: provider.client_id, verify_aud: true, verify_iat: true, required_claims: %w[iss aud exp iat sub nonce email])
    raise InvalidResponse unless claims["email_verified"] == true && claims["email"].is_a?(String)
    raise InvalidResponse unless claims["sub"].is_a?(String) && claims["sub"].present?
    raise InvalidResponse unless claims["nonce"] == nonce
    if claims.key?("azp") || Array(claims["aud"]).many?
      raise InvalidResponse unless claims["azp"] == provider.client_id
    end
    claims
  rescue JWT::DecodeError, OpenSSL::OpenSSLError, ArgumentError, KeyError, TypeError
    raise InvalidResponse, cause: nil
  end

  # A missing key ID is unambiguous only with one eligible signing key.
  def self.matching_keys(keys, header)
    keys.select do |key|
      key["kty"] == KEY_TYPES.fetch(header["alg"]) && (!header.key?("kid") || key["kid"] == header["kid"]) &&
        (!key.key?("alg") || key["alg"] == header["alg"]) && (!key.key?("use") || key["use"] == "sig") &&
        (!key.key?("key_ops") || Array(key["key_ops"]).include?("verify")) &&
        (key["kty"] != "EC" || key["crv"] == "P-256")
    end
  end
end

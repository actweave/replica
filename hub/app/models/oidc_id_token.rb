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

    # The JWT date validators expect values convertible to NumericDate.
    payload = encoded.unverified_payload
    raise InvalidResponse unless payload.is_a?(Hash) && payload["exp"].is_a?(Integer) && payload["iat"].is_a?(Integer)
    raise InvalidResponse if payload.key?("nbf") && !payload["nbf"].is_a?(Integer)

    claims = verified_payload(token, provider, header, yield(false)) ||
      verified_payload(token, provider, header, yield(true))
    raise InvalidResponse unless claims
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

  # Only a missing key or a signature mismatch merits one fetch of the latest keys.
  def self.verified_payload(token, provider, header, key_set)
    keys = matching_keys(key_set, header)
    return if keys.empty?
    raise InvalidResponse unless keys.one?

    key = JWT::JWK.import(keys.first).verify_key
    JWT.decode(token, key, true, algorithm: header.fetch("alg"), iss: provider.issuer, verify_iss: true,
      aud: provider.client_id, verify_aud: true, verify_iat: true, required_claims: %w[iss aud exp iat sub nonce email]).first
  rescue JWT::VerificationError
    nil
  end
  private_class_method :verified_payload

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

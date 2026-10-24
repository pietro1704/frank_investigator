require "openssl"
require "base64"

module Llm
  module Chatgpt
    class Identity
      def self.verify(token, client_id:, nonce: nil, subject: nil)
        parts = token.to_s.split(".", -1)
        raise Error.new("invalid_identity_token") unless parts.size == 3
        header64, payload64, signature64 = parts
        header = JSON.parse(Base64.urlsafe_decode64(header64.to_s))
        raise Error.new("invalid_identity_algorithm") unless header["alg"] == "RS256"
        jwks = Transport.new.json("https://auth.openai.com/.well-known/jwks.json")
        key = jwks.fetch("keys").find { |candidate| candidate["kid"] == header["kid"] && candidate["kty"] == "RSA" }
        raise Error.new("unknown_identity_key") unless key
        numbers = %w[n e].map { |name| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(Base64.urlsafe_decode64(key.fetch(name)), 2)) }
        public_key = OpenSSL::PKey::RSA.new(OpenSSL::ASN1::Sequence.new(numbers).to_der)
        valid = public_key.verify(OpenSSL::Digest::SHA256.new, Base64.urlsafe_decode64(signature64.to_s), "#{header64}.#{payload64}")
        raise Error.new("invalid_identity_signature") unless valid
        claims = JSON.parse(Base64.urlsafe_decode64(payload64.to_s))
        unless claims["iss"] == "https://auth.openai.com" && Array(claims["aud"]).include?(client_id) &&
            (claims["azp"].nil? || claims["azp"] == client_id) &&
            (Array(claims["aud"]).size == 1 || claims["azp"] == client_id) &&
            claims["exp"].to_i > Time.now.to_i && claims["sub"].present? &&
            (nonce.nil? || claims["nonce"] == nonce) && (subject.nil? || claims["sub"] == subject)
          raise Error.new("identity_mismatch")
        end
        claims
      rescue ArgumentError, JSON::ParserError, KeyError, OpenSSL::OpenSSLError
        raise Error.new("invalid_identity_token")
      end
    end
  end
end

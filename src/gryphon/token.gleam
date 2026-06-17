import gleam/bit_array
import gleam/crypto
import gleam/result
import gleam/string
import gryphon/types

pub fn generate_tunnel_token() -> String {
  random_urlsafe(32)
}

pub fn generate_tunnel_id() -> types.TunnelId {
  types.TunnelId(random_urlsafe(16))
}

pub fn generate_correlation_id() -> String {
  random_urlsafe(12)
}

pub fn hash_token(token: String) -> types.TunnelTokenHash {
  let salt = crypto.strong_random_bytes(16)
  let digest =
    crypto.hash(crypto.Sha256, bit_array.append(salt, <<token:utf8>>))
  let encoded_salt = bit_array.base64_url_encode(salt, False)
  let encoded_digest = bit_array.base64_url_encode(digest, False)
  types.TunnelTokenHash(encoded_salt <> ":" <> encoded_digest)
}

pub fn verify_token(token: String, stored: types.TunnelTokenHash) -> Bool {
  let types.TunnelTokenHash(raw) = stored
  case string.split_once(raw, ":") {
    Ok(#(encoded_salt, encoded_digest)) -> {
      use salt <- result.try(bit_array.base64_url_decode(encoded_salt))
      use digest <- result.try(bit_array.base64_url_decode(encoded_digest))
      let challenge =
        crypto.hash(crypto.Sha256, bit_array.append(salt, <<token:utf8>>))
      Ok(crypto.secure_compare(challenge, digest))
    }
    Error(_) -> Ok(False)
  }
  |> result.unwrap(False)
}

pub fn random_subdomain_candidate() -> String {
  "g" <> random_hex(5)
}

fn random_urlsafe(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes)
  |> bit_array.base64_url_encode(False)
}

fn random_hex(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

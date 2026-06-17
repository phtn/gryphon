import gleam/http.{type Header}
import gleam/option.{type Option}

pub type TunnelId {
  TunnelId(value: String)
}

pub type TunnelTokenHash {
  TunnelTokenHash(value: String)
}

pub type Tunnel {
  Tunnel(
    id: TunnelId,
    subdomain: String,
    token_hash: TunnelTokenHash,
    created_at: Int,
    revoked_at: Option(Int),
  )
}

pub type TunnelSession {
  TunnelSession(subdomain: String)
}

pub type ForwardRequest {
  ForwardRequest(
    request_id: String,
    method: String,
    path: String,
    headers: List(Header),
    body: BitArray,
    forwarded_for: String,
    forwarded_host: String,
    forwarded_proto: String,
    correlation_id: String,
  )
}

pub type ForwardResponse {
  ForwardResponse(
    request_id: String,
    status: Int,
    headers: List(Header),
    body: BitArray,
  )
}

pub type ProtocolMessage {
  Hello
  HelloOk(tunnel_id: String, subdomain: String)
  Request(ForwardRequest)
  Response(ForwardResponse)
  Error(request_id: Option(String), status: Int, message: String)
  Heartbeat
}

pub fn tunnel_id_string(id: TunnelId) -> String {
  let TunnelId(value) = id
  value
}

pub fn tunnel_hash_string(hash: TunnelTokenHash) -> String {
  let TunnelTokenHash(value) = hash
  value
}

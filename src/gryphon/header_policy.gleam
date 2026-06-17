import gleam/http.{type Header}
import gleam/list
import gleam/string

pub fn sanitize_request_headers(
  headers: List(Header),
  forwarded_for: String,
  forwarded_host: String,
  forwarded_proto: String,
  correlation_id: String,
) -> List(Header) {
  headers
  |> list.filter(fn(header) { !is_blocked_request_header(header.0) })
  |> upsert("x-forwarded-for", forwarded_for)
  |> upsert("x-forwarded-host", forwarded_host)
  |> upsert("x-forwarded-proto", forwarded_proto)
  |> upsert("x-request-id", correlation_id)
}

pub fn sanitize_response_headers(headers: List(Header)) -> List(Header) {
  headers
  |> list.filter(fn(header) { !is_blocked_response_header(header.0) })
}

pub fn is_upgrade_request(headers: List(Header)) -> Bool {
  list.any(headers, fn(header) {
    header.0 == "upgrade"
    || {
      header.0 == "connection"
      && string.contains(string.lowercase(header.1), "upgrade")
    }
  })
}

fn upsert(headers: List(Header), key: String, value: String) -> List(Header) {
  let filtered = list.filter(headers, fn(header) { header.0 != key })
  [#(key, value), ..filtered]
}

fn is_blocked_request_header(key: String) -> Bool {
  let key = string.lowercase(key)
  key == "connection"
  || key == "keep-alive"
  || key == "transfer-encoding"
  || key == "upgrade"
  || key == "forwarded"
  || key == "host"
  || string.starts_with(key, "x-forwarded-")
}

fn is_blocked_response_header(key: String) -> Bool {
  let key = string.lowercase(key)
  key == "connection"
  || key == "keep-alive"
  || key == "transfer-encoding"
  || key == "upgrade"
  || key == "proxy-connection"
}

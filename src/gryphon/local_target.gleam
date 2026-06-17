import gleam/http
import gleam/http/request as http_request
import gleam/int
import gleam/option
import gleam/result
import gleam/string
import gryphon/types

pub type LocalTarget {
  LocalTarget(
    scheme: http.Scheme,
    host: String,
    port: option.Option(Int),
    base_path: String,
  )
}

pub fn parse(url: String) -> Result(LocalTarget, String) {
  use request <- result.try(
    http_request.to(url)
    |> result.replace_error("local-url must be a valid absolute URL"),
  )

  case is_loopback_host(request.host) {
    False -> Error("local-url host must be one of localhost, 127.0.0.1, or ::1")
    True ->
      Ok(LocalTarget(
        request.scheme,
        request.host,
        request.port,
        normalize_base_path(request.path),
      ))
  }
}

pub fn to_request(
  target: LocalTarget,
  forwarded: types.ForwardRequest,
) -> Result(http_request.Request(BitArray), String) {
  use method <- result.try(
    http.parse_method(forwarded.method)
    |> result.replace_error("forwarded request uses an invalid HTTP method"),
  )

  let #(path, query) = split_query(forwarded.path)
  let host_header = host_header(target.host, target.port, target.scheme)

  Ok(http_request.Request(
    method: method,
    headers: [#("host", host_header), ..forwarded.headers],
    body: forwarded.body,
    scheme: target.scheme,
    host: target.host,
    port: target.port,
    path: join_paths(target.base_path, path),
    query: query,
  ))
}

fn is_loopback_host(host: String) -> Bool {
  let host = string.lowercase(host)
  host == "localhost" || host == "127.0.0.1" || host == "::1"
}

fn normalize_base_path(path: String) -> String {
  case path {
    "" -> ""
    "/" -> ""
    _ ->
      case string.starts_with(path, "/") {
        True -> trim_single_trailing_slash(path)
        False -> "/" <> trim_single_trailing_slash(path)
      }
  }
}

fn join_paths(base_path: String, path: String) -> String {
  let path = case path {
    "" -> "/"
    _ ->
      case string.starts_with(path, "/") {
        True -> path
        False -> "/" <> path
      }
  }

  case base_path {
    "" -> path
    _ if path == "/" -> base_path
    _ -> base_path <> path
  }
}

fn split_query(path: String) -> #(String, option.Option(String)) {
  case string.split_once(path, "?") {
    Ok(#(left, right)) -> #(left, option.Some(right))
    Error(_) -> #(path, option.None)
  }
}

fn host_header(
  host: String,
  port: option.Option(Int),
  scheme: http.Scheme,
) -> String {
  case port {
    option.None -> host
    option.Some(value) -> {
      let default_port = case scheme {
        http.Http -> 80
        http.Https -> 443
      }
      case value == default_port {
        True -> host
        False -> host <> ":" <> int.to_string(value)
      }
    }
  }
}

fn trim_single_trailing_slash(path: String) -> String {
  case string.ends_with(path, "/") {
    True ->
      string.slice(from: path, at_index: 0, length: string.length(path) - 1)
    False -> path
  }
}

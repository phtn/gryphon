import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gryphon/runtime

const default_interval_ms = 2000

const request_timeout_ms = 5000

pub type Config {
  Config(server_url: String, admin_token: String, interval_ms: Int, once: Bool)
}

pub type Snapshot {
  Snapshot(tunnels: List(TunnelRow), sessions: List(SessionRow))
}

pub type TunnelRow {
  TunnelRow(
    id: String,
    subdomain: String,
    status: String,
    created_at: Int,
    revoked_at: Option(Int),
    connected_at: Option(Int),
  )
}

pub type SessionRow {
  SessionRow(tunnel_id: String, subdomain: String, connected_at: Option(Int))
}

pub fn default_interval() -> Int {
  default_interval_ms
}

pub fn run(config: Config) -> Nil {
  loop(config)
}

fn loop(config: Config) -> Nil {
  case fetch_snapshot(config) {
    Ok(snapshot) -> render(config, snapshot)
    Error(error) -> render_error(config, error)
  }

  case config.once {
    True -> Nil
    False -> {
      process_sleep(config.interval_ms)
      loop(config)
    }
  }
}

fn fetch_snapshot(config: Config) -> Result(Snapshot, String) {
  let endpoint = status_url(config.server_url)
  use req <- result.try(
    request.to(endpoint)
    |> result.map(fn(req) {
      req
      |> request.set_header("authorization", "Bearer " <> config.admin_token)
      |> request.set_header("accept", "application/json")
    })
    |> result.map_error(fn(_) { "invalid server URL" }),
  )

  let http_config = httpc.configure() |> httpc.timeout(request_timeout_ms)

  use response <- result.try(
    httpc.dispatch(http_config, req)
    |> result.map_error(http_error_to_string(_, endpoint)),
  )

  case response.status >= 200 && response.status < 300 {
    True ->
      json.parse(response.body, snapshot_decoder())
      |> result.map_error(fn(error) {
        "invalid dashboard JSON: " <> string.inspect(error)
      })
    False ->
      Error(
        "dashboard API returned HTTP "
        <> int.to_string(response.status)
        <> ": "
        <> response.body,
      )
  }
}

fn render(config: Config, snapshot: Snapshot) -> Nil {
  clear_screen()
  io.println("Gryphon dashboard")
  io.println("server: " <> config.server_url)
  io.println("updated_at_ms: " <> int.to_string(runtime.unix_millis()))
  io.println("")
  io.println(
    "tunnels: "
    <> int.to_string(list.length(snapshot.tunnels))
    <> " | sessions: "
    <> int.to_string(list.length(snapshot.sessions)),
  )
  io.println("")
  io.println(
    pad("SUBDOMAIN", 24)
    <> pad("STATUS", 12)
    <> pad("CREATED_MS", 16)
    <> pad("CONNECTED_MS", 16),
  )
  io.println(string.repeat("-", times: 68))

  list.each(snapshot.tunnels, fn(tunnel) {
    io.println(
      pad(tunnel.subdomain, 24)
      <> pad(tunnel.status, 12)
      <> pad(int.to_string(tunnel.created_at), 16)
      <> pad(optional_int(tunnel.connected_at), 16),
    )
  })

  io.println("")
  io.println("Ctrl-C to stop")
}

fn render_error(config: Config, error: String) -> Nil {
  clear_screen()
  io.println("Gryphon dashboard")
  io.println("server: " <> config.server_url)
  io.println("updated_at_ms: " <> int.to_string(runtime.unix_millis()))
  io.println("")
  io.println("error: " <> error)
  io.println("")
  io.println("Ctrl-C to stop")
}

fn snapshot_decoder() -> decode.Decoder(Snapshot) {
  use tunnels <- decode.field("tunnels", decode.list(of: tunnel_decoder()))
  use sessions <- decode.field("sessions", decode.list(of: session_decoder()))
  decode.success(Snapshot(tunnels:, sessions:))
}

fn tunnel_decoder() -> decode.Decoder(TunnelRow) {
  use id <- decode.field("id", decode.string)
  use subdomain <- decode.field("subdomain", decode.string)
  use status <- decode.field("status", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use revoked_at <- decode.field("revoked_at", decode.optional(decode.int))
  use connected_at <- decode.field("connected_at", decode.optional(decode.int))
  decode.success(TunnelRow(
    id:,
    subdomain:,
    status:,
    created_at:,
    revoked_at:,
    connected_at:,
  ))
}

fn session_decoder() -> decode.Decoder(SessionRow) {
  use tunnel_id <- decode.field("tunnel_id", decode.string)
  use subdomain <- decode.field("subdomain", decode.string)
  use connected_at <- decode.field("connected_at", decode.optional(decode.int))
  decode.success(SessionRow(tunnel_id:, subdomain:, connected_at:))
}

fn status_url(server_url: String) -> String {
  let normalized = case
    string.starts_with(server_url, "http://")
    || string.starts_with(server_url, "https://")
  {
    True -> server_url
    False -> "http://" <> server_url
  }

  let base = case string.ends_with(normalized, "/") {
    True -> string.drop_end(normalized, up_to: 1)
    False -> normalized
  }

  base <> "/v1/admin/status"
}

fn http_error_to_string(error: httpc.HttpError, endpoint: String) -> String {
  case error {
    httpc.ResponseTimeout -> "dashboard API request timed out at " <> endpoint
    httpc.InvalidUtf8Response ->
      "dashboard API returned invalid UTF-8 from " <> endpoint
    httpc.FailedToConnect(_, _) ->
      "failed to connect to dashboard API at "
      <> endpoint
      <> "; start the relay server or use its listening host and port"
  }
}

fn pad(value: String, width: Int) -> String {
  string.slice(value, at_index: 0, length: width - 1)
  |> string.pad_end(to: width, with: " ")
}

fn optional_int(value: Option(Int)) -> String {
  case value {
    Some(inner) -> int.to_string(inner)
    None -> "-"
  }
}

fn clear_screen() -> Nil {
  io.print("\u{1b}[2J\u{1b}[H")
}

fn process_sleep(milliseconds: Int) -> Nil {
  process.sleep(milliseconds)
}

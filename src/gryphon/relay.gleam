import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import gryphon/control_json
import gryphon/header_policy
import gryphon/protocol
import gryphon/runtime
import gryphon/session
import gryphon/state
import gryphon/subdomain
import gryphon/token
import gryphon/types
import logging
import mist

const request_body_limit = 1_048_576

const request_timeout_ms = 30_000

const max_in_flight = 32

const heartbeat_interval_ms = 15_000

const heartbeat_timeout_ms = 45_000

pub type Config {
  Config(
    interface: String,
    port: Int,
    base_domain: String,
    admin_token: Option(String),
    state_subject: process.Subject(state.Message),
  )
}

type SessionState {
  SessionState(
    state_subject: process.Subject(state.Message),
    tunnel: types.Tunnel,
    control: process.Subject(session.SessionCommand),
    pending: dict.Dict(String, process.Subject(session.SessionResult)),
    last_heartbeat_at: Int,
  )
}

fn builder(config: Config) {
  mist.new(handle_request(config, _))
  |> mist.bind(config.interface)
  |> mist.port(config.port)
  |> mist.after_start(fn(port, _scheme, _ip) {
    logging.log(
      logging.Info,
      "{\"event\":\"relay_started\",\"port\":"
        <> int.to_string(port)
        <> ",\"base_domain\":\""
        <> config.base_domain
        <> "\"}",
    )
  })
}

pub fn start(
  config: Config,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  builder(config)
  |> mist.start
}

pub fn supervised(
  config: Config,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  builder(config)
  |> mist.supervised
}

fn handle_request(
  config: Config,
  request: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  case request.path == "/healthz" || request.path == "/readyz" {
    True -> response_with_text(200, "ok")
    False ->
      case string.starts_with(request.path, "/v1/admin/") {
        True -> handle_admin_request(config, request)
        False ->
          case request.path == "/v1/agent/connect" {
            True -> handle_agent_connect(config, request)
            False -> handle_public_request(config, request)
          }
      }
  }
}

fn handle_admin_request(
  config: Config,
  request: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  case config.admin_token {
    None -> response_with_text(404, "admin API is disabled")
    Some(expected_token) ->
      case bearer_token(request) {
        Some(provided_token) if provided_token == expected_token ->
          route_admin_request(config, request)
        _ -> admin_unauthorized_response()
      }
  }
}

fn route_admin_request(
  config: Config,
  request: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  case request.path {
    "/v1/admin/tunnels" ->
      response_with_json(
        200,
        state.snapshot(config.state_subject)
          |> control_json.dashboard_snapshot,
      )

    "/v1/admin/sessions" ->
      response_with_json(
        200,
        state.snapshot(config.state_subject)
          |> control_json.session_snapshot,
      )

    "/v1/admin/status" ->
      response_with_json(
        200,
        state.snapshot(config.state_subject)
          |> control_json.dashboard_snapshot,
      )

    _ -> response_with_text(404, "unknown admin endpoint")
  }
}

fn handle_agent_connect(
  config: Config,
  request: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  let token = bearer_token(request)

  case token {
    None -> unauthorized_response("missing bearer token")
    Some(value) -> {
      case state.authenticate_agent(config.state_subject, value) {
        Some(tunnel) ->
          mist.websocket(
            request: request,
            handler: session_handler,
            on_init: init_session(config.state_subject, tunnel, _),
            on_close: close_session,
          )
        None -> unauthorized_response("invalid token")
      }
    }
  }
}

fn handle_public_request(
  config: Config,
  request: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  let remote_ip = client_ip(request)
  case mist.read_body(request, request_body_limit) {
    Error(mist.ExcessBody) ->
      response_with_text(413, "request body exceeds the 1 MiB limit")
    Error(mist.MalformedBody) ->
      response_with_text(400, "request body could not be parsed")
    Ok(with_body) ->
      case header_policy.is_upgrade_request(with_body.headers) {
        True ->
          response_with_text(
            501,
            "streaming and upgrades are not supported in v1",
          )
        False -> route_public_request(config, with_body, remote_ip)
      }
  }
}

fn route_public_request(
  config: Config,
  request: http_request.Request(BitArray),
  remote_ip: String,
) -> http_response.Response(mist.ResponseData) {
  case http_request.get_header(request, "host") {
    Error(_) -> response_with_text(400, "missing host header")
    Ok(host_header) ->
      case subdomain.from_host(host_header, config.base_domain) {
        Error(_) -> response_with_text(404, "unknown tunnel host")
        Ok(tunnel_subdomain) ->
          case state.resolve_route(config.state_subject, tunnel_subdomain) {
            state.UnknownSubdomain ->
              response_with_text(404, "unknown tunnel host")

            state.OfflineTunnel(_tunnel) ->
              response_with_text(503, "tunnel is offline")

            state.OnlineTunnel(_tunnel, session_subject) -> {
              let forwarded_request =
                build_forward_request(request, host_header, remote_ip)
              let reply_subject = process.new_subject()

              process.send(
                session_subject,
                session.Forward(
                  reply_to: reply_subject,
                  request: forwarded_request,
                ),
              )

              case process.receive(reply_subject, within: request_timeout_ms) {
                Ok(session.Forwarded(forwarded_response)) ->
                  response_from_forwarded(forwarded_response)

                Ok(session.Failed(status, message)) ->
                  response_with_text(status, message)

                Error(_) ->
                  response_with_text(504, "upstream tunnel request timed out")
              }
            }
          }
      }
  }
}

fn build_forward_request(
  request: http_request.Request(BitArray),
  original_host: String,
  remote_ip: String,
) -> types.ForwardRequest {
  let path = case request.query {
    Some(query) -> request.path <> "?" <> query
    None -> request.path
  }
  let correlation_id = token.generate_correlation_id()

  types.ForwardRequest(
    request_id: token.generate_correlation_id(),
    method: http.method_to_string(request.method),
    path: path,
    headers: header_policy.sanitize_request_headers(
      request.headers,
      remote_ip,
      original_host,
      "http",
      correlation_id,
    ),
    body: request.body,
    forwarded_for: remote_ip,
    forwarded_host: original_host,
    forwarded_proto: "http",
    correlation_id: correlation_id,
  )
}

fn init_session(
  state_subject: process.Subject(state.Message),
  tunnel: types.Tunnel,
  connection: mist.WebsocketConnection,
) -> #(SessionState, Option(process.Selector(session.SessionCommand))) {
  let control = process.new_subject()
  let last_heartbeat_at = runtime.monotonic_millis()

  state.register_session(state_subject, tunnel, control)
  let _ =
    mist.send_text_frame(
      connection,
      protocol.encode(types.HelloOk(
        tunnel_id: types.tunnel_id_string(tunnel.id),
        subdomain: tunnel.subdomain,
      )),
    )
  process.send_after(control, heartbeat_interval_ms, session.LivenessCheck)

  #(
    SessionState(
      state_subject: state_subject,
      tunnel: tunnel,
      control: control,
      pending: dict.new(),
      last_heartbeat_at: last_heartbeat_at,
    ),
    Some(process.new_selector() |> process.select(control)),
  )
}

fn close_session(state: SessionState) -> Nil {
  dict.each(state.pending, fn(_request_id, reply_to) {
    session.fail(reply_to, 503, "tunnel session disconnected")
  })
  state.unregister_session(
    state.state_subject,
    state.tunnel.subdomain,
    state.control,
  )
  logging.log(
    logging.Info,
    "{\"event\":\"tunnel_disconnected\",\"subdomain\":\""
      <> state.tunnel.subdomain
      <> "\"}",
  )
}

fn session_handler(
  state: SessionState,
  message: mist.WebsocketMessage(session.SessionCommand),
  connection: mist.WebsocketConnection,
) -> mist.Next(SessionState, session.SessionCommand) {
  case message {
    mist.Text(payload) -> handle_protocol_message(state, payload)
    mist.Binary(_) ->
      mist.stop_abnormal("binary websocket messages are unsupported")
    mist.Closed -> mist.stop()
    mist.Shutdown -> mist.stop()
    mist.Custom(command) -> handle_session_command(state, command, connection)
  }
}

fn handle_protocol_message(
  state: SessionState,
  payload: String,
) -> mist.Next(SessionState, session.SessionCommand) {
  case protocol.decode(payload) {
    Ok(types.Hello) ->
      mist.continue(
        SessionState(..state, last_heartbeat_at: runtime.monotonic_millis()),
      )

    Ok(types.Heartbeat) ->
      mist.continue(
        SessionState(..state, last_heartbeat_at: runtime.monotonic_millis()),
      )

    Ok(types.Response(response)) -> resolve_pending_response(state, response)

    Ok(types.Error(Some(request_id), status, message)) ->
      resolve_pending_error(state, request_id, status, message)

    Ok(_) -> mist.stop_abnormal("unexpected protocol message from agent")

    Error(error) -> {
      logging.log(logging.Warning, error)
      mist.stop_abnormal("invalid protocol message from agent")
    }
  }
}

fn handle_session_command(
  state: SessionState,
  command: session.SessionCommand,
  connection: mist.WebsocketConnection,
) -> mist.Next(SessionState, session.SessionCommand) {
  case command {
    session.Forward(reply_to, request) -> {
      case dict.size(state.pending) >= max_in_flight {
        True -> {
          session.fail(reply_to, 503, "tunnel is at its concurrency limit")
          mist.continue(state)
        }

        False -> {
          case
            mist.send_text_frame(
              connection,
              protocol.encode(types.Request(request)),
            )
          {
            Ok(Nil) ->
              mist.continue(
                SessionState(
                  ..state,
                  pending: dict.insert(
                    state.pending,
                    request.request_id,
                    reply_to,
                  ),
                ),
              )

            Error(_reason) -> {
              session.fail(
                reply_to,
                502,
                "failed to send request to tunnel agent",
              )
              mist.continue(state)
            }
          }
        }
      }
    }

    session.ForceDisconnect ->
      mist.stop_abnormal("session replaced by a newer connection")

    session.LivenessCheck -> {
      let now = runtime.monotonic_millis()
      case now - state.last_heartbeat_at > heartbeat_timeout_ms {
        True -> mist.stop_abnormal("heartbeat timeout")
        False -> {
          process.send_after(
            state.control,
            heartbeat_interval_ms,
            session.LivenessCheck,
          )
          mist.continue(state)
        }
      }
    }
  }
}

fn resolve_pending_response(
  state: SessionState,
  response: types.ForwardResponse,
) -> mist.Next(SessionState, session.SessionCommand) {
  let pending = dict.get(state.pending, response.request_id)
  case pending {
    Ok(reply_to) -> {
      process.send(reply_to, session.Forwarded(response))
      mist.continue(
        SessionState(
          ..state,
          pending: dict.delete(state.pending, response.request_id),
          last_heartbeat_at: runtime.monotonic_millis(),
        ),
      )
    }
    Error(_) ->
      mist.continue(
        SessionState(..state, last_heartbeat_at: runtime.monotonic_millis()),
      )
  }
}

fn resolve_pending_error(
  state: SessionState,
  request_id: String,
  status: Int,
  message: String,
) -> mist.Next(SessionState, session.SessionCommand) {
  let pending = dict.get(state.pending, request_id)
  case pending {
    Ok(reply_to) -> {
      session.fail(reply_to, status, message)
      mist.continue(
        SessionState(
          ..state,
          pending: dict.delete(state.pending, request_id),
          last_heartbeat_at: runtime.monotonic_millis(),
        ),
      )
    }
    Error(_) ->
      mist.continue(
        SessionState(..state, last_heartbeat_at: runtime.monotonic_millis()),
      )
  }
}

fn response_from_forwarded(
  forwarded: types.ForwardResponse,
) -> http_response.Response(mist.ResponseData) {
  list.fold(
    forwarded.headers,
    http_response.new(forwarded.status),
    fn(acc, header) { http_response.set_header(acc, header.0, header.1) },
  )
  |> http_response.set_body(
    mist.Bytes(bytes_tree.from_bit_array(forwarded.body)),
  )
}

fn response_with_text(
  status: Int,
  body: String,
) -> http_response.Response(mist.ResponseData) {
  http_response.new(status)
  |> http_response.set_header("content-type", "text/plain; charset=utf-8")
  |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn response_with_json(
  status: Int,
  body: String,
) -> http_response.Response(mist.ResponseData) {
  http_response.new(status)
  |> http_response.set_header("content-type", "application/json")
  |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn unauthorized_response(
  message: String,
) -> http_response.Response(mist.ResponseData) {
  logging.log(
    logging.Warning,
    "{\"event\":\"agent_auth_failed\",\"reason\":\"" <> message <> "\"}",
  )
  response_with_text(401, message)
}

fn admin_unauthorized_response() -> http_response.Response(mist.ResponseData) {
  logging.log(logging.Warning, "{\"event\":\"admin_auth_failed\"}")
  response_with_text(401, "invalid admin token")
}

fn bearer_token(request: http_request.Request(body)) -> Option(String) {
  case http_request.get_header(request, "authorization") {
    Ok(value) ->
      case string.starts_with(value, "Bearer ") {
        True ->
          Some(string.slice(
            from: value,
            at_index: 7,
            length: string.length(value) - 7,
          ))
        False -> None
      }
    _ -> None
  }
}

fn client_ip(request: http_request.Request(mist.Connection)) -> String {
  case mist.get_connection_info(request.body) {
    Ok(info) -> mist.ip_address_to_string(info.ip_address)
    Error(_) -> "unknown"
  }
}

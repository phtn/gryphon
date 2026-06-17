import collie
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/option
import gleam/result
import gryphon/header_policy
import gryphon/local_target
import gryphon/protocol
import gryphon/types
import logging

const response_body_limit = 4_194_304

const request_timeout_ms = 30_000

const heartbeat_interval_ms = 15_000

const max_in_flight = 32

pub type Config {
  Config(
    server_url: String,
    token: String,
    local_target: local_target.LocalTarget,
  )
}

pub type Message {
  SendHello
  HeartbeatTick
  LocalResponse(types.ForwardResponse)
  LocalError(request_id: String, status: Int, message: String)
}

type State {
  State(
    self: process.Subject(collie.WebsocketMessage(Message)),
    local_target: local_target.LocalTarget,
    in_flight: Int,
  )
}

pub fn start(config: Config) {
  let assert Ok(request) =
    request.to(config.server_url <> "/v1/agent/connect")
    |> result.map(fn(req) {
      req
      |> request.set_header("authorization", "Bearer " <> config.token)
    })

  collie.new_with_initialiser(request, fn(self) {
    process.send(self, collie.to_user_message(SendHello))
    process.send_after(
      self,
      heartbeat_interval_ms,
      collie.to_user_message(HeartbeatTick),
    )
    Ok(
      collie.initialised(State(
        self: self,
        local_target: config.local_target,
        in_flight: 0,
      ))
      |> collie.returning(self),
    )
  })
  |> collie.with_connection_timeout(5000)
  |> collie.on_message(handle_message)
  |> collie.on_close(fn(_state, reason) {
    logging.log(
      logging.Warning,
      "{\"event\":\"agent_disconnected\",\"reason\":\""
        <> collie.close_reason_to_string(reason)
        <> "\"}",
    )
  })
  |> collie.start
}

fn handle_message(
  connection: collie.Connection,
  state: State,
  message: collie.Message(Message),
) -> collie.Next(State, Message) {
  case message {
    collie.User(SendHello) -> {
      let _ = collie.send_text_frame(connection, protocol.encode(types.Hello))
      collie.continue(state)
    }

    collie.User(HeartbeatTick) -> {
      let _ =
        collie.send_text_frame(connection, protocol.encode(types.Heartbeat))
      process.send_after(
        state.self,
        heartbeat_interval_ms,
        collie.to_user_message(HeartbeatTick),
      )
      collie.continue(state)
    }

    collie.User(LocalResponse(forwarded_response)) -> {
      let _ =
        collie.send_text_frame(
          connection,
          protocol.encode(types.Response(forwarded_response)),
        )
      collie.continue(State(..state, in_flight: decrement(state.in_flight)))
    }

    collie.User(LocalError(request_id, status, message)) -> {
      let _ =
        collie.send_text_frame(
          connection,
          protocol.encode(types.Error(option.Some(request_id), status, message)),
        )
      collie.continue(State(..state, in_flight: decrement(state.in_flight)))
    }

    collie.Text(payload) -> handle_protocol_payload(state, payload)
    collie.Binary(_) ->
      collie.stop_abnormal("binary protocol frames are unsupported")
  }
}

fn handle_protocol_payload(
  state: State,
  payload: String,
) -> collie.Next(State, Message) {
  case protocol.decode(payload) {
    Ok(types.HelloOk(_tunnel_id, subdomain)) -> {
      logging.log(
        logging.Info,
        "{\"event\":\"agent_connected\",\"subdomain\":\"" <> subdomain <> "\"}",
      )
      collie.continue(state)
    }

    Ok(types.Request(forwarded_request)) -> {
      case state.in_flight >= max_in_flight {
        True -> {
          process.send(
            state.self,
            collie.to_user_message(LocalError(
              request_id: forwarded_request.request_id,
              status: 503,
              message: "agent concurrency limit exceeded",
            )),
          )
          collie.continue(state)
        }

        False -> {
          spawn_local_request(state.self, state.local_target, forwarded_request)
          collie.continue(State(..state, in_flight: state.in_flight + 1))
        }
      }
    }

    Ok(types.Heartbeat) -> collie.continue(state)
    Ok(types.Error(_, _, _)) -> collie.continue(state)
    Ok(types.Hello) -> collie.continue(state)
    Ok(types.Response(_)) -> collie.continue(state)

    Error(error) -> {
      logging.log(logging.Warning, error)
      collie.stop_abnormal("invalid protocol payload")
    }
  }
}

fn spawn_local_request(
  subject: process.Subject(collie.WebsocketMessage(Message)),
  target: local_target.LocalTarget,
  forwarded_request: types.ForwardRequest,
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      let result = forward_to_local_target(target, forwarded_request)
      case result {
        Ok(response) ->
          process.send(subject, collie.to_user_message(LocalResponse(response)))
        Error(#(status, message)) ->
          process.send(
            subject,
            collie.to_user_message(LocalError(
              request_id: forwarded_request.request_id,
              status: status,
              message: message,
            )),
          )
      }
    })

  Nil
}

fn forward_to_local_target(
  target: local_target.LocalTarget,
  forwarded_request: types.ForwardRequest,
) -> Result(types.ForwardResponse, #(Int, String)) {
  use request <- result.try(
    local_target.to_request(target, forwarded_request)
    |> result.replace_error(#(502, "invalid local target request")),
  )

  let config = httpc.configure() |> httpc.timeout(request_timeout_ms)

  use response <- result.try(
    httpc.dispatch_bits(config, request)
    |> result.map_error(fn(error) {
      case error {
        httpc.ResponseTimeout -> #(504, "local upstream timed out")
        httpc.InvalidUtf8Response -> #(
          502,
          "local upstream returned invalid UTF-8",
        )
        httpc.FailedToConnect(_, _) -> #(
          502,
          "failed to connect to local upstream",
        )
      }
    }),
  )

  case bit_array.byte_size(response.body) > response_body_limit {
    True -> Error(#(413, "local upstream response exceeded 4 MiB"))
    False ->
      Ok(types.ForwardResponse(
        request_id: forwarded_request.request_id,
        status: response.status,
        headers: header_policy.sanitize_response_headers(response.headers),
        body: response.body,
      ))
  }
}

fn decrement(value: Int) -> Int {
  case value <= 0 {
    True -> 0
    False -> value - 1
  }
}

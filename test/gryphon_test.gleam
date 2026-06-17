import gleam/erlang/process
import gleam/http/request as http_request
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit
import gryphon
import gryphon/header_policy
import gryphon/local_target
import gryphon/protocol
import gryphon/runtime
import gryphon/session
import gryphon/state
import gryphon/store
import gryphon/subdomain
import gryphon/token
import gryphon/types
import sqlight

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn subdomain_validation_test() {
  assert Ok("dev-app") == subdomain.validate("Dev-App")
  assert Ok("preview")
    == subdomain.from_host("preview.example.test", "example.test")
  let assert Error(_) = subdomain.validate("-invalid")
  let assert Error(_) = subdomain.from_host("example.test", "example.test")
}

pub fn token_hash_verification_test() {
  let hashed = token.hash_token("super-secret")

  assert token.verify_token("super-secret", hashed)
  assert !token.verify_token("wrong-secret", hashed)
}

pub fn header_policy_request_sanitization_test() {
  let headers =
    [
      #("host", "evil.example"),
      #("connection", "upgrade"),
      #("x-forwarded-for", "10.0.0.1"),
      #("content-type", "application/json"),
    ]
    |> header_policy.sanitize_request_headers(
      "127.0.0.1",
      "demo.example.test",
      "http",
      "corr-123",
    )

  assert Error(Nil) == list.key_find(headers, "host")
  assert Error(Nil) == list.key_find(headers, "connection")
  assert Ok("127.0.0.1") == list.key_find(headers, "x-forwarded-for")
  assert Ok("demo.example.test") == list.key_find(headers, "x-forwarded-host")
  assert Ok("http") == list.key_find(headers, "x-forwarded-proto")
  assert Ok("corr-123") == list.key_find(headers, "x-request-id")
  assert Ok("application/json") == list.key_find(headers, "content-type")
}

pub fn header_policy_response_sanitization_test() {
  let headers =
    [
      #("connection", "keep-alive"),
      #("proxy-connection", "keep-alive"),
      #("transfer-encoding", "chunked"),
      #("content-type", "text/plain"),
    ]
    |> header_policy.sanitize_response_headers

  assert Error(Nil) == list.key_find(headers, "connection")
  assert Error(Nil) == list.key_find(headers, "proxy-connection")
  assert Error(Nil) == list.key_find(headers, "transfer-encoding")
  assert Ok("text/plain") == list.key_find(headers, "content-type")
}

pub fn header_policy_upgrade_detection_test() {
  assert header_policy.is_upgrade_request([
    #("connection", "keep-alive, Upgrade"),
  ])
  assert header_policy.is_upgrade_request([#("upgrade", "websocket")])
  assert !header_policy.is_upgrade_request([
    #("content-type", "application/json"),
  ])
}

pub fn local_target_validation_and_request_build_test() {
  let assert Ok(target) = local_target.parse("http://127.0.0.1:4001/internal")
  let forwarded =
    types.ForwardRequest(
      request_id: "req-1",
      method: "POST",
      path: "/health?ok=yes",
      headers: [#("content-type", "application/json")],
      body: <<"{\"ok\":true}":utf8>>,
      forwarded_for: "127.0.0.1",
      forwarded_host: "demo.example.test",
      forwarded_proto: "http",
      correlation_id: "corr-1",
    )

  let assert Ok(local_request) = local_target.to_request(target, forwarded)

  assert local_request.host == "127.0.0.1"
  assert local_request.path == "/internal/health"
  assert local_request.query == option.Some("ok=yes")
  assert Ok("127.0.0.1:4001") == http_request.get_header(local_request, "host")
  let assert Error(_) = local_target.parse("http://192.168.1.10:8080")
}

pub fn local_target_base_path_and_validation_test() {
  let assert Ok(target) = local_target.parse("http://127.0.0.1:3000/api")
  let forwarded =
    types.ForwardRequest(
      request_id: "req-2",
      method: "GET",
      path: "/users?sort=asc",
      headers: [],
      body: <<>>,
      forwarded_for: "127.0.0.1",
      forwarded_host: "demo.example.test",
      forwarded_proto: "http",
      correlation_id: "corr-2",
    )

  let assert Ok(local_request) = local_target.to_request(target, forwarded)

  assert local_request.path == "/api/users"
  assert local_request.query == option.Some("sort=asc")
  assert Ok("127.0.0.1:3000") == http_request.get_header(local_request, "host")

  let assert Error(_) = local_target.parse("http://10.0.0.1:3000")
  let assert Error(_) = local_target.parse("not-a-url")
}

pub fn protocol_decode_error_test() {
  let assert Error(_) = protocol.decode("not json")
}

pub fn protocol_roundtrip_test() {
  let message =
    types.Request(types.ForwardRequest(
      request_id: "req-1",
      method: "GET",
      path: "/hello?name=gryphon",
      headers: [#("accept", "application/json")],
      body: <<"payload":utf8>>,
      forwarded_for: "127.0.0.1",
      forwarded_host: "demo.example.test",
      forwarded_proto: "http",
      correlation_id: "corr-1",
    ))

  let encoded = protocol.encode(message)
  assert Ok(message) == protocol.decode(encoded)
}

pub fn runtime_join_errors_test() {
  assert runtime.join_errors(["", "first", "", "second"]) == "second, first"
}

pub fn terminate_server_and_agent_test() {
  let server_pid = process.spawn_unlinked(fn() { process.sleep_forever() })
  let agent_pid = process.spawn_unlinked(fn() { process.sleep_forever() })

  let server = actor.Started(pid: server_pid, data: Nil)
  let agent = actor.Started(pid: agent_pid, data: Nil)

  gryphon.terminate_server_and_agent(server, agent)

  process.sleep(10)
  assert !process.is_alive(server_pid)
  assert !process.is_alive(agent_pid)
}

pub fn session_fail_sends_message_test() {
  let subject = process.new_subject()
  let _ = session.fail(subject, 502, "bad gateway")

  let assert Ok(session.Failed(status: 502, message: "bad gateway")) =
    process.receive(subject, within: 1000)
}

pub fn state_route_and_session_lifecycle_test() {
  let db_path = temp_db_path("state")
  let assert Ok(started) = state.start(db_path)
  let state_subject = started.data

  use connection <- sqlight.with_connection(db_path)
  let assert Ok(Nil) = store.ensure_schema(connection)
  let assert Ok(#(created, token_value)) =
    store.create_tunnel(connection, option.Some("demo"), 1000)

  assert state.resolve_route(state_subject, "missing") == state.UnknownSubdomain
  assert state.authenticate_agent(state_subject, "wrong-token") == option.None
  assert state.authenticate_agent(state_subject, token_value)
    == option.Some(created)

  let assert state.OfflineTunnel(offline_tunnel) =
    state.resolve_route(state_subject, "demo")
  assert offline_tunnel == created

  let control_1 = process.new_subject()
  state.register_session(state_subject, created, control_1)

  let assert state.OnlineTunnel(online_tunnel, session_subject) =
    state.resolve_route(state_subject, "demo")
  assert online_tunnel == created
  assert session_subject == control_1

  let control_2 = process.new_subject()
  state.register_session(state_subject, created, control_2)

  let assert Ok(session.ForceDisconnect) =
    process.receive(control_1, within: 1000)

  let assert state.OnlineTunnel(_, session_subject) =
    state.resolve_route(state_subject, "demo")
  assert session_subject == control_2

  state.unregister_session(state_subject, "demo", control_2)

  let assert state.OfflineTunnel(unregistered_tunnel) =
    state.resolve_route(state_subject, "demo")
  assert unregistered_tunnel == created
}

pub fn subdomain_normalize_and_host_parse_test() {
  assert subdomain.normalize_host("Example.Test:443") == "example.test"
  assert subdomain.normalize_host("[::1]:4000") == "[::1]:4000"
  assert Ok("preview")
    == subdomain.from_host("Preview.Example.Test:443", "Example.Test")
  let assert Error(_) = subdomain.from_host("example.test", "example.test")
}

pub fn token_random_subdomain_candidate_shape_test() {
  let candidate = token.random_subdomain_candidate()

  assert string.starts_with(candidate, "g")
  assert string.length(candidate) == 11
  let assert Ok(validated) = subdomain.validate(candidate)
  assert validated == candidate
}

pub fn sqlite_tunnel_lifecycle_test() {
  use connection <- sqlight.with_connection(":memory:")
  let assert Ok(Nil) = store.ensure_schema(connection)
  let assert Ok(#(created, token_value)) =
    store.create_tunnel(connection, option.Some("demo"), 1000)

  let assert Ok(option.Some(found)) =
    store.find_by_subdomain(connection, "demo")
  assert created.subdomain == found.subdomain

  let assert Ok(option.Some(authenticated)) =
    store.find_active_by_token(connection, token_value)
  assert authenticated.subdomain == "demo"

  let assert Ok(True) = store.revoke_tunnel(connection, "demo", 2000)
  let assert Ok(option.None) =
    store.find_active_by_token(connection, token_value)

  let assert Ok(tunnels) = store.list_tunnels(connection)
  assert list.length(tunnels) == 1
}

fn temp_db_path(prefix: String) -> String {
  "/tmp/gryphon-"
  <> prefix
  <> "-"
  <> int.to_string(runtime.unix_millis())
  <> "-"
  <> token.generate_correlation_id()
  <> ".db"
}

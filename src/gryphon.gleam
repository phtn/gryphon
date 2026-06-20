import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gryphon/agent
import gryphon/control_json
import gryphon/dashboard
import gryphon/local_target
import gryphon/relay
import gryphon/runtime
import gryphon/state
import gryphon/store
import gryphon/subdomain
import logging
import sqlight

pub fn main() -> Nil {
  logging.configure()

  case runtime.ensure_runtime_prereqs() {
    Ok(Nil) -> run(runtime.plain_arguments())
    Error(error) -> runtime.fatal(error)
  }
}

pub fn terminate_server_and_agent(
  server: actor.Started(a),
  agent: actor.Started(b),
) -> Nil {
  process.kill(agent.pid)
  process.kill(server.pid)
}

fn run(arguments: List(String)) -> Nil {
  case arguments {
    ["server", ..rest] -> run_server(rest)
    ["agent", ..rest] -> run_agent(rest)
    ["dashboard", ..rest] -> run_dashboard(rest)
    ["admin", "create-tunnel", ..rest] -> run_admin_create_tunnel(rest)
    ["admin", "revoke-tunnel", ..rest] -> run_admin_revoke_tunnel(rest)
    ["admin", "list-tunnels", ..rest] -> run_admin_list_tunnels(rest)
    _ -> print_usage()
  }
}

fn run_dashboard(arguments: List(String)) -> Nil {
  let options = parse_options(arguments, [])
  let server_url = require_option(options, "--server-url")
  let admin_token = require_option(options, "--admin-token")
  let interval_ms = parse_interval_ms(get_option(options, "--interval-ms"))
  let once = has_flag(arguments, "--once")

  case server_url, admin_token, interval_ms {
    Ok(server_url), Ok(admin_token), Ok(interval_ms) ->
      dashboard.run(dashboard.Config(
        server_url: server_url,
        admin_token: admin_token,
        interval_ms: interval_ms,
        once: once,
      ))
    _, _, _ ->
      runtime.fatal(
        runtime.join_errors([
          result.unwrap_error(server_url, ""),
          result.unwrap_error(admin_token, ""),
          result.unwrap_error(interval_ms, ""),
        ]),
      )
  }
}

fn run_server(arguments: List(String)) -> Nil {
  let options = parse_options(arguments, [])
  let listen = get_option(options, "--listen") |> option.unwrap("0.0.0.0:4000")
  let db_path = get_option(options, "--db-path") |> option.unwrap("gryphon.db")
  let admin_token = get_option(options, "--admin-token")
  let base_domain = require_option(options, "--base-domain")

  case base_domain {
    Error(message) -> runtime.fatal(message)
    Ok(base_domain) -> {
      case parse_listen(listen) {
        Error(message) -> runtime.fatal(message)
        Ok(#(interface, port)) -> {
          let assert Ok(started) = state.start(db_path)
          let state_subject = started.data

          let assert Ok(_relay) =
            relay.start(relay.Config(
              interface: interface,
              port: port,
              base_domain: base_domain,
              admin_token: admin_token,
              state_subject: state_subject,
            ))
          process.sleep_forever()
        }
      }
    }
  }
}

fn run_agent(arguments: List(String)) -> Nil {
  let options = parse_options(arguments, [])
  let server_url = require_option(options, "--server-url")
  let token = require_option(options, "--token")
  let local_url = require_option(options, "--local-url")

  case server_url, token, local_url {
    Ok(server_url), Ok(token), Ok(local_url) -> {
      case local_target.parse(local_url) {
        Ok(target) -> {
          let assert Ok(_started) =
            agent.start(agent.Config(
              server_url: server_url,
              token: token,
              local_target: target,
            ))
          process.sleep_forever()
        }
        Error(message) -> runtime.fatal(message)
      }
    }
    _, _, _ ->
      runtime.fatal(
        runtime.join_errors([
          result.unwrap_error(server_url, ""),
          result.unwrap_error(token, ""),
          result.unwrap_error(local_url, ""),
        ]),
      )
  }
}

fn run_admin_create_tunnel(arguments: List(String)) -> Nil {
  let options = parse_options(arguments, [])
  let json_output = has_flag(arguments, "--json")
  let db_path = get_option(options, "--db-path") |> option.unwrap("gryphon.db")
  let requested_subdomain = case get_option(options, "--subdomain") {
    option.Some(value) -> subdomain.validate(value) |> result.map(option.Some)
    option.None -> Ok(option.None)
  }

  case requested_subdomain {
    Error(message) -> runtime.fatal(message)
    Ok(maybe_subdomain) -> {
      use connection <- sqlight.with_connection(db_path)
      let assert Ok(Nil) = store.ensure_schema(connection)
      let assert Ok(#(tunnel, token_value)) =
        store.create_tunnel(connection, maybe_subdomain, runtime.unix_millis())

      case json_output {
        True -> io.println(control_json.created_tunnel(tunnel, token_value))
        False -> {
          io.println("subdomain=" <> tunnel.subdomain)
          io.println("token=" <> token_value)
        }
      }
    }
  }
}

fn run_admin_revoke_tunnel(arguments: List(String)) -> Nil {
  let options = parse_options(arguments, [])
  let json_output = has_flag(arguments, "--json")
  let db_path = get_option(options, "--db-path") |> option.unwrap("gryphon.db")
  let requested_subdomain = require_option(options, "--subdomain")

  case requested_subdomain {
    Ok(value) -> {
      use connection <- sqlight.with_connection(db_path)
      let assert Ok(Nil) = store.ensure_schema(connection)
      let assert Ok(revoked) =
        store.revoke_tunnel(connection, value, runtime.unix_millis())

      case json_output {
        True -> io.println(control_json.revoked_tunnel(value, revoked))
        False -> {
          case revoked {
            True -> io.println("revoked " <> value)
            False -> io.println("no active tunnel found for " <> value)
          }
        }
      }
    }
    Error(message) -> runtime.fatal(message)
  }
}

fn run_admin_list_tunnels(arguments: List(String)) -> Nil {
  let options = parse_options(arguments, [])
  let json_output = has_flag(arguments, "--json")
  let db_path = get_option(options, "--db-path") |> option.unwrap("gryphon.db")

  use connection <- sqlight.with_connection(db_path)
  let assert Ok(Nil) = store.ensure_schema(connection)
  let assert Ok(tunnels) = store.list_tunnels(connection)

  case json_output {
    True -> io.println(control_json.tunnel_list(tunnels))
    False ->
      list.each(tunnels, fn(tunnel) {
        let revoked = case tunnel.revoked_at {
          option.Some(value) -> "revoked@" <> int.to_string(value)
          option.None -> "active"
        }
        io.println(tunnel.subdomain <> " " <> revoked)
      })
  }
}

fn print_usage() -> Nil {
  io.println(
    "gryphon server --listen <host:port> --base-domain <domain> --db-path <path> [--admin-token <token>]",
  )
  io.println(
    "gryphon agent --server-url <url> --token <token> --local-url <url>",
  )
  io.println(
    "gryphon dashboard --server-url <url> --admin-token <token> [--interval-ms <ms>] [--once]",
  )
  io.println(
    "gryphon admin create-tunnel --db-path <path> [--subdomain <value>] [--json]",
  )
  io.println(
    "gryphon admin revoke-tunnel --db-path <path> --subdomain <value> [--json]",
  )
  io.println("gryphon admin list-tunnels --db-path <path> [--json]")
}

fn parse_options(
  arguments: List(String),
  collected: List(#(String, String)),
) -> List(#(String, String)) {
  case arguments {
    [key, value, ..rest] ->
      case string.starts_with(key, "--") {
        True -> parse_options(rest, [#(key, value), ..collected])
        False -> collected
      }

    [] -> collected
    _ -> collected
  }
}

fn get_option(
  options: List(#(String, String)),
  key: String,
) -> option.Option(String) {
  case
    list.find_map(options, fn(option) {
      case option.0 == key {
        True -> Ok(option.1)
        False -> Error(Nil)
      }
    })
  {
    Ok(value) -> option.Some(value)
    Error(_) -> option.None
  }
}

fn has_flag(arguments: List(String), flag: String) -> Bool {
  list.any(arguments, fn(argument) { argument == flag })
}

fn parse_interval_ms(value: option.Option(String)) -> Result(Int, String) {
  case value {
    option.None -> Ok(dashboard.default_interval())
    option.Some(raw) ->
      case int.parse(raw) {
        Ok(parsed) if parsed > 0 -> Ok(parsed)
        _ -> Error("invalid --interval-ms, expected a positive integer")
      }
  }
}

fn require_option(
  options: List(#(String, String)),
  key: String,
) -> Result(String, String) {
  get_option(options, key)
  |> option.to_result("missing required option " <> key)
}

fn parse_listen(value: String) -> Result(#(String, Int), String) {
  case string.split_once(value, ":") {
    Ok(#(interface, port)) -> {
      use parsed_port <- result.try(
        int.parse(port)
        |> result.replace_error("--listen port must be an integer"),
      )
      Ok(#(interface, parsed_port))
    }
    Error(_) -> Error("--listen must use the format host:port")
  }
}

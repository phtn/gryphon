import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gryphon/runtime
import gryphon/session
import gryphon/store
import gryphon/types
import logging
import sqlight

pub type RouteResult {
  UnknownSubdomain
  OfflineTunnel(types.Tunnel)
  OnlineTunnel(types.Tunnel, process.Subject(session.SessionCommand))
}

pub type TunnelStatus {
  Online
  Offline
  Revoked
}

pub type TunnelSnapshot {
  TunnelSnapshot(
    tunnel: types.Tunnel,
    status: TunnelStatus,
    connected_at: Option(Int),
  )
}

pub type Message {
  ResolveRoute(reply_to: process.Subject(RouteResult), subdomain: String)
  AuthenticateAgent(
    reply_to: process.Subject(Option(types.Tunnel)),
    token: String,
  )
  RegisterSession(
    reply_to: process.Subject(Nil),
    tunnel: types.Tunnel,
    session: process.Subject(session.SessionCommand),
    connected_at: Int,
  )
  UnregisterSession(
    tunnel_subdomain: String,
    session: process.Subject(session.SessionCommand),
  )
  Snapshot(reply_to: process.Subject(List(TunnelSnapshot)))
}

type ActiveSession {
  ActiveSession(
    control: process.Subject(session.SessionCommand),
    connected_at: Int,
  )
}

type State {
  State(
    connection: sqlight.Connection,
    sessions: dict.Dict(String, ActiveSession),
  )
}

pub fn start(
  db_path: String,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    use connection <- result.try(
      sqlight.open(db_path)
      |> result.map_error(fn(error) {
        let sqlight.SqlightError(_code, message, _offset) = error
        message
      }),
    )
    use _ <- result.try(store.ensure_schema(connection))
    Ok(
      actor.initialised(State(connection, dict.new()))
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(
  db_path: String,
) -> supervision.ChildSpecification(process.Subject(Message)) {
  supervision.worker(fn() { start(db_path) })
}

pub fn resolve_route(
  subject: process.Subject(Message),
  requested_subdomain: String,
) -> RouteResult {
  process.call(subject, 5000, ResolveRoute(_, requested_subdomain))
}

pub fn authenticate_agent(
  subject: process.Subject(Message),
  token: String,
) -> Option(types.Tunnel) {
  process.call(subject, 5000, AuthenticateAgent(_, token))
}

pub fn register_session(
  subject: process.Subject(Message),
  tunnel: types.Tunnel,
  control: process.Subject(session.SessionCommand),
) -> Nil {
  process.call(subject, 5000, RegisterSession(
    _,
    tunnel,
    control,
    runtime.unix_millis(),
  ))
}

pub fn unregister_session(
  subject: process.Subject(Message),
  tunnel_subdomain: String,
  control: process.Subject(session.SessionCommand),
) -> Nil {
  process.send(subject, UnregisterSession(tunnel_subdomain:, session: control))
}

pub fn snapshot(subject: process.Subject(Message)) -> List(TunnelSnapshot) {
  process.call(subject, 5000, Snapshot)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    ResolveRoute(reply_to, requested_subdomain) -> {
      let route = case
        store.find_by_subdomain(state.connection, requested_subdomain)
      {
        Ok(Some(tunnel)) ->
          case dict.get(state.sessions, requested_subdomain) {
            Ok(active) -> OnlineTunnel(tunnel, active.control)
            Error(_) -> OfflineTunnel(tunnel)
          }
        Ok(None) -> UnknownSubdomain
        Error(error) -> {
          logging.log(logging.Error, error)
          UnknownSubdomain
        }
      }
      process.send(reply_to, route)
      actor.continue(state)
    }

    AuthenticateAgent(reply_to, token) -> {
      let tunnel =
        store.find_active_by_token(state.connection, token)
        |> result.unwrap(None)

      process.send(reply_to, tunnel)
      actor.continue(state)
    }

    RegisterSession(reply_to, tunnel, control, connected_at) -> {
      let sessions = case dict.get(state.sessions, tunnel.subdomain) {
        Ok(previous) if previous.control != control -> {
          process.send(previous.control, session.ForceDisconnect)
          dict.insert(
            state.sessions,
            tunnel.subdomain,
            ActiveSession(control:, connected_at:),
          )
        }
        _ ->
          dict.insert(
            state.sessions,
            tunnel.subdomain,
            ActiveSession(control:, connected_at:),
          )
      }

      process.send(reply_to, Nil)
      actor.continue(State(..state, sessions: sessions))
    }

    UnregisterSession(tunnel_subdomain, control) -> {
      let sessions = case dict.get(state.sessions, tunnel_subdomain) {
        Ok(current) if current.control == control ->
          dict.delete(state.sessions, tunnel_subdomain)
        _ -> state.sessions
      }

      actor.continue(State(..state, sessions: sessions))
    }

    Snapshot(reply_to) -> {
      let snapshots = case store.list_tunnels(state.connection) {
        Ok(tunnels) ->
          list.map(tunnels, fn(tunnel) {
            case tunnel.revoked_at {
              Some(_) ->
                TunnelSnapshot(
                  tunnel: tunnel,
                  status: Revoked,
                  connected_at: None,
                )
              None ->
                case dict.get(state.sessions, tunnel.subdomain) {
                  Ok(active) ->
                    TunnelSnapshot(
                      tunnel: tunnel,
                      status: Online,
                      connected_at: Some(active.connected_at),
                    )
                  Error(_) ->
                    TunnelSnapshot(
                      tunnel: tunnel,
                      status: Offline,
                      connected_at: None,
                    )
                }
            }
          })
        Error(error) -> {
          logging.log(logging.Error, error)
          []
        }
      }

      process.send(reply_to, snapshots)
      actor.continue(state)
    }
  }
}

import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
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
  )
  UnregisterSession(
    tunnel_subdomain: String,
    session: process.Subject(session.SessionCommand),
  )
}

type State {
  State(
    connection: sqlight.Connection,
    sessions: dict.Dict(String, process.Subject(session.SessionCommand)),
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
  process.call(subject, 5000, RegisterSession(_, tunnel, control))
}

pub fn unregister_session(
  subject: process.Subject(Message),
  tunnel_subdomain: String,
  control: process.Subject(session.SessionCommand),
) -> Nil {
  process.send(subject, UnregisterSession(tunnel_subdomain:, session: control))
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
            Ok(session_subject) -> OnlineTunnel(tunnel, session_subject)
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

    RegisterSession(reply_to, tunnel, control) -> {
      let sessions = case dict.get(state.sessions, tunnel.subdomain) {
        Ok(previous) if previous != control -> {
          process.send(previous, session.ForceDisconnect)
          dict.insert(state.sessions, tunnel.subdomain, control)
        }
        _ -> dict.insert(state.sessions, tunnel.subdomain, control)
      }

      process.send(reply_to, Nil)
      actor.continue(State(..state, sessions: sessions))
    }

    UnregisterSession(tunnel_subdomain, control) -> {
      let sessions = case dict.get(state.sessions, tunnel_subdomain) {
        Ok(current) if current == control ->
          dict.delete(state.sessions, tunnel_subdomain)
        _ -> state.sessions
      }

      actor.continue(State(..state, sessions: sessions))
    }
  }
}

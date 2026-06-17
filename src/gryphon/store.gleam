import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gryphon/subdomain
import gryphon/token
import gryphon/types
import sqlight

const schema = "
create table if not exists tunnels (
  id text primary key,
  subdomain text not null unique,
  token_hash text not null,
  created_at integer not null,
  revoked_at integer
);
"

pub fn ensure_schema(connection: sqlight.Connection) -> Result(Nil, String) {
  sqlight.exec(schema, on: connection)
  |> result.map_error(error_to_string)
}

pub fn create_tunnel(
  connection: sqlight.Connection,
  requested_subdomain: Option(String),
  now_millis: Int,
) -> Result(#(types.Tunnel, String), String) {
  let token_value = token.generate_tunnel_token()
  let token_hash = token.hash_token(token_value)
  let tunnel_id = token.generate_tunnel_id()
  use chosen_subdomain <- result.try(choose_subdomain(
    connection,
    requested_subdomain,
    0,
  ))

  let tunnel =
    types.Tunnel(
      id: tunnel_id,
      subdomain: chosen_subdomain,
      token_hash: token_hash,
      created_at: now_millis,
      revoked_at: None,
    )

  use _ <- result.try(insert_tunnel(connection, tunnel))
  Ok(#(tunnel, token_value))
}

pub fn revoke_tunnel(
  connection: sqlight.Connection,
  requested_subdomain: String,
  now_millis: Int,
) -> Result(Bool, String) {
  use valid_subdomain <- result.try(subdomain.validate(requested_subdomain))
  use existing <- result.try(find_by_subdomain(connection, valid_subdomain))

  case existing {
    None -> Ok(False)
    Some(_tunnel) -> {
      sqlight.query(
        "
        update tunnels
        set revoked_at = ?
        where subdomain = ? and revoked_at is null
        returning id
        ",
        on: connection,
        with: [sqlight.int(now_millis), sqlight.text(valid_subdomain)],
        expecting: single_string_decoder(),
      )
      |> result.map(fn(rows) { !list.is_empty(rows) })
      |> result.map_error(error_to_string)
    }
  }
}

pub fn list_tunnels(
  connection: sqlight.Connection,
) -> Result(List(types.Tunnel), String) {
  sqlight.query(
    "
    select id, subdomain, token_hash, created_at, revoked_at
    from tunnels
    order by created_at asc
    ",
    on: connection,
    with: [],
    expecting: tunnel_decoder(),
  )
  |> result.map_error(error_to_string)
}

pub fn find_by_subdomain(
  connection: sqlight.Connection,
  requested_subdomain: String,
) -> Result(Option(types.Tunnel), String) {
  sqlight.query(
    "
    select id, subdomain, token_hash, created_at, revoked_at
    from tunnels
    where subdomain = ?
    limit 1
    ",
    on: connection,
    with: [sqlight.text(requested_subdomain)],
    expecting: tunnel_decoder(),
  )
  |> result.map(first_option)
  |> result.map_error(error_to_string)
}

pub fn find_active_by_token(
  connection: sqlight.Connection,
  provided_token: String,
) -> Result(Option(types.Tunnel), String) {
  use tunnels <- result.try(
    sqlight.query(
      "
      select id, subdomain, token_hash, created_at, revoked_at
      from tunnels
      where revoked_at is null
      ",
      on: connection,
      with: [],
      expecting: tunnel_decoder(),
    )
    |> result.map_error(error_to_string),
  )

  Ok(
    case
      list.find(tunnels, fn(tunnel) {
        token.verify_token(provided_token, tunnel.token_hash)
      })
    {
      Ok(tunnel) -> Some(tunnel)
      Error(_) -> None
    },
  )
}

fn choose_subdomain(
  connection: sqlight.Connection,
  requested_subdomain: Option(String),
  attempts: Int,
) -> Result(String, String) {
  case requested_subdomain {
    Some(value) -> subdomain.validate(value)
    None -> {
      case attempts >= 10 {
        True -> Error("failed to allocate a unique random subdomain")
        False -> {
          let candidate = subdomain.random()
          use existing <- result.try(find_by_subdomain(connection, candidate))
          case existing {
            Some(_) -> choose_subdomain(connection, None, attempts + 1)
            None -> Ok(candidate)
          }
        }
      }
    }
  }
}

fn insert_tunnel(
  connection: sqlight.Connection,
  tunnel: types.Tunnel,
) -> Result(Nil, String) {
  sqlight.query(
    "
    insert into tunnels (id, subdomain, token_hash, created_at, revoked_at)
    values (?, ?, ?, ?, null)
    returning id
    ",
    on: connection,
    with: [
      sqlight.text(types.tunnel_id_string(tunnel.id)),
      sqlight.text(tunnel.subdomain),
      sqlight.text(types.tunnel_hash_string(tunnel.token_hash)),
      sqlight.int(tunnel.created_at),
    ],
    expecting: single_string_decoder(),
  )
  |> result.map(fn(_rows) { Nil })
  |> result.map_error(error_to_string)
}

fn tunnel_decoder() -> decode.Decoder(types.Tunnel) {
  use id <- decode.field(0, decode.string)
  use subdomain <- decode.field(1, decode.string)
  use token_hash <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.int)
  use revoked_at <- decode.field(4, decode.optional(decode.int))

  decode.success(types.Tunnel(
    id: types.TunnelId(id),
    subdomain: subdomain,
    token_hash: types.TunnelTokenHash(token_hash),
    created_at: created_at,
    revoked_at: revoked_at,
  ))
}

fn single_string_decoder() -> decode.Decoder(String) {
  use value <- decode.field(0, decode.string)
  decode.success(value)
}

fn first_option(items: List(a)) -> Option(a) {
  case items {
    [first, ..] -> Some(first)
    [] -> None
  }
}

fn error_to_string(error: sqlight.Error) -> String {
  let sqlight.SqlightError(_code, message, _offset) = error
  message
}

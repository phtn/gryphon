import gleam/json
import gleam/list
import gleam/option
import gryphon/state
import gryphon/types

pub fn created_tunnel(tunnel: types.Tunnel, token: String) -> String {
  json.object([
    #("subdomain", json.string(tunnel.subdomain)),
    #("token", json.string(token)),
    #("tunnel", tunnel_json(tunnel)),
  ])
  |> json.to_string
}

pub fn revoked_tunnel(subdomain: String, revoked: Bool) -> String {
  json.object([
    #("subdomain", json.string(subdomain)),
    #("revoked", json.bool(revoked)),
  ])
  |> json.to_string
}

pub fn tunnel_list(tunnels: List(types.Tunnel)) -> String {
  json.object([
    #("tunnels", json.array(tunnels, tunnel_json)),
  ])
  |> json.to_string
}

pub fn dashboard_snapshot(snapshots: List(state.TunnelSnapshot)) -> String {
  json.object([
    #("tunnels", json.array(snapshots, snapshot_json)),
    #("sessions", json.array(active_sessions(snapshots), session_json)),
  ])
  |> json.to_string
}

pub fn session_snapshot(snapshots: List(state.TunnelSnapshot)) -> String {
  json.object([
    #("sessions", json.array(active_sessions(snapshots), session_json)),
  ])
  |> json.to_string
}

fn snapshot_json(snapshot: state.TunnelSnapshot) -> json.Json {
  json.object([
    #("id", json.string(types.tunnel_id_string(snapshot.tunnel.id))),
    #("subdomain", json.string(snapshot.tunnel.subdomain)),
    #("status", json.string(status_to_string(snapshot.status))),
    #("created_at", json.int(snapshot.tunnel.created_at)),
    #("revoked_at", json.nullable(snapshot.tunnel.revoked_at, json.int)),
    #("connected_at", json.nullable(snapshot.connected_at, json.int)),
  ])
}

fn session_json(snapshot: state.TunnelSnapshot) -> json.Json {
  json.object([
    #("tunnel_id", json.string(types.tunnel_id_string(snapshot.tunnel.id))),
    #("subdomain", json.string(snapshot.tunnel.subdomain)),
    #("connected_at", json.nullable(snapshot.connected_at, json.int)),
  ])
}

fn tunnel_json(tunnel: types.Tunnel) -> json.Json {
  json.object([
    #("id", json.string(types.tunnel_id_string(tunnel.id))),
    #("subdomain", json.string(tunnel.subdomain)),
    #("created_at", json.int(tunnel.created_at)),
    #("revoked_at", json.nullable(tunnel.revoked_at, json.int)),
  ])
}

fn active_sessions(
  snapshots: List(state.TunnelSnapshot),
) -> List(state.TunnelSnapshot) {
  list.filter(snapshots, fn(snapshot) {
    case snapshot.status, snapshot.connected_at {
      state.Online, option.Some(_) -> True
      _, _ -> False
    }
  })
}

fn status_to_string(status: state.TunnelStatus) -> String {
  case status {
    state.Online -> "online"
    state.Offline -> "offline"
    state.Revoked -> "revoked"
  }
}

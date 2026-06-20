# gryphon

[![Package Version](https://img.shields.io/hexpm/v/gryphon)](https://hex.pm/packages/gryphon)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/gryphon/)

Gryphon is a reverse tunnel service built in Gleam. It has three pieces:

- a public relay server
- a local agent that forwards traffic to a local HTTP service
- an admin CLI for managing tunnel records in SQLite

## Install

```sh
gleam add gryphon@1
```

## Quick Start

1. Start the relay server with a base domain that points at it.

```sh
export GRYPHON_ADMIN_TOKEN="$(openssl rand -base64 32)"

gleam run -- server \
  --listen 0.0.0.0:4000 \
  --base-domain example.test \
  --db-path gryphon.db \
  --admin-token "$GRYPHON_ADMIN_TOKEN"
```

2. Create a tunnel and copy the printed token.

```sh
gleam run -- admin create-tunnel --db-path gryphon.db --json
```

Example output:

```json
{"subdomain":"demo","token":"...","tunnel":{"id":"...","subdomain":"demo","created_at":1710000000000,"revoked_at":null}}
```

3. Start the agent and point it at your local app.

```sh
gleam run -- agent --server-url http://127.0.0.1:4000 --token <token> --local-url http://127.0.0.1:3000
```

4. Open the tunnel in a browser.

```text
http://<subdomain>.example.test/
```

## Usage Guide

### Relay server

The relay accepts public traffic and routes requests to the active agent for each subdomain.

Required flags:

- `--base-domain <domain>`: the suffix used to map hostnames to tunnels

Optional flags:

- `--listen <host:port>`: bind address, defaults to `0.0.0.0:4000`
- `--db-path <path>`: SQLite database path, defaults to `gryphon.db`
- `--admin-token <token>`: enables bearer-token protected control-plane endpoints

Example:

```sh
gleam run -- server \
  --listen 0.0.0.0:4000 \
  --base-domain example.test \
  --db-path gryphon.db \
  --admin-token "$GRYPHON_ADMIN_TOKEN"
```

Health and readiness:

```sh
curl -fSs http://127.0.0.1:4000/healthz
curl -fSs http://127.0.0.1:4000/readyz
```

### Agent

The agent connects to the relay over WebSocket and forwards requests to a local HTTP service.

Required flags:

- `--server-url <url>`: relay base URL, for example `http://127.0.0.1:4000`
- `--token <token>`: tunnel token printed by `admin create-tunnel`
- `--local-url <url>`: local upstream URL, for example `http://127.0.0.1:3000`

Notes:

- `--local-url` must be an absolute URL.
- The host must be loopback: `localhost`, `127.0.0.1`, or `::1`.

Example:

```sh
gleam run -- agent --server-url http://127.0.0.1:4000 --token <token> --local-url http://127.0.0.1:3000
```

### Shutdown

If you start Gryphon components from your own Gleam code, use the exported helper to stop both processes together.

```gleam
import gryphon

pub fn stop(server, agent) -> Nil {
  gryphon.terminate_server_and_agent(server, agent)
}
```

The helper expects the started server and agent handles returned by the runtime APIs and terminates both processes with `process.kill`.

### Admin commands

Use the admin commands to manage tunnel records in the SQLite database.

Create a tunnel:

```sh
gleam run -- admin create-tunnel --db-path gryphon.db
```

Optionally reserve a specific subdomain:

```sh
gleam run -- admin create-tunnel --db-path gryphon.db --subdomain demo
```

List tunnels:

```sh
gleam run -- admin list-tunnels --db-path gryphon.db
```

List tunnels as JSON for automation:

```sh
gleam run -- admin list-tunnels --db-path gryphon.db --json
```

Revoke a tunnel:

```sh
gleam run -- admin revoke-tunnel --db-path gryphon.db --subdomain demo
```

All admin commands support `--json` when their output is consumed by scripts or
a dashboard client.

### Control-plane API

When the relay is started with `--admin-token`, Gryphon exposes a small JSON API
for command-and-control dashboards. These endpoints are disabled unless the
token is configured.

```sh
curl -fSs http://127.0.0.1:4000/v1/admin/status \
  -H "Authorization: Bearer $GRYPHON_ADMIN_TOKEN" | jq
```

Available endpoints:

- `GET /v1/admin/status`: tunnel records plus active sessions
- `GET /v1/admin/tunnels`: same dashboard snapshot, optimized for tunnel tables
- `GET /v1/admin/sessions`: active agent sessions only

Example response:

```json
{
  "tunnels": [
    {
      "id": "tun_...",
      "subdomain": "demo",
      "status": "online",
      "created_at": 1710000000000,
      "revoked_at": null,
      "connected_at": 1710000010000
    }
  ],
  "sessions": [
    {
      "tunnel_id": "tun_...",
      "subdomain": "demo",
      "connected_at": 1710000010000
    }
  ]
}
```

These APIs are the intended foundation for a running CLI dashboard. The
dashboard should poll these endpoints, render status, and call admin actions
rather than scrape relay logs or parse human-oriented output.

Run the built-in terminal dashboard:

```sh
gleam run -- dashboard \
  --server-url http://127.0.0.1:4000 \
  --admin-token "$GRYPHON_ADMIN_TOKEN"
```

`--server-url` may be a full URL or a bare host such as `127.0.0.1:4000`.
Use a connectable host for the dashboard; `0.0.0.0` is for server binding.

For scripts and smoke tests, render once and exit:

```sh
gleam run -- dashboard \
  --server-url http://127.0.0.1:4000 \
  --admin-token "$GRYPHON_ADMIN_TOKEN" \
  --once
```

## Complete Setup Guide

### 1. Prepare DNS

Point a wildcard record at the relay host:

```text
*.example.com -> <relay-ip>
```

For local development, use a test domain that resolves to `127.0.0.1`, or pass
`--resolve` to `curl`:

```sh
curl --resolve demo.example.test:4000:127.0.0.1 \
  http://demo.example.test:4000/
```

### 2. Create the server

Create a persistent database directory and an admin token:

```sh
mkdir -p ./data
export GRYPHON_ADMIN_TOKEN="$(openssl rand -base64 32)"
```

Start the relay:

```sh
gleam run -- server \
  --listen 0.0.0.0:4000 \
  --base-domain example.test \
  --db-path ./data/gryphon.db \
  --admin-token "$GRYPHON_ADMIN_TOKEN"
```

Verify the relay:

```sh
curl -fSs http://127.0.0.1:4000/healthz
curl -fSs http://127.0.0.1:4000/v1/admin/status \
  -H "Authorization: Bearer $GRYPHON_ADMIN_TOKEN" | jq
```

### 3. Create an agent tunnel

Create a tunnel record and keep the token:

```sh
gleam run -- admin create-tunnel \
  --db-path ./data/gryphon.db \
  --subdomain demo \
  --json | jq
```

Start a local HTTP app to expose. For example:

```sh
python3 -m http.server 3000
```

Start the Gryphon agent:

```sh
gleam run -- agent \
  --server-url http://127.0.0.1:4000 \
  --token "<token-from-create-tunnel>" \
  --local-url http://127.0.0.1:3000
```

Check that the dashboard snapshot shows the tunnel as online:

```sh
curl -fSs http://127.0.0.1:4000/v1/admin/status \
  -H "Authorization: Bearer $GRYPHON_ADMIN_TOKEN" | jq
```

Or open the live CLI dashboard:

```sh
gleam run -- dashboard \
  --server-url http://127.0.0.1:4000 \
  --admin-token "$GRYPHON_ADMIN_TOKEN"
```

Open the tunnel:

```sh
curl --resolve demo.example.test:4000:127.0.0.1 \
  http://demo.example.test:4000/
```

### 4. Production deployment

Build and run the container with a persistent volume:

```sh
docker build -t gryphon .

export GRYPHON_ADMIN_TOKEN="$(openssl rand -base64 32)"

docker run --rm \
  -p 4000:4000 \
  -v gryphon-data:/data \
  gryphon \
  run server \
  --listen 0.0.0.0:4000 \
  --base-domain example.com \
  --db-path /data/gryphon.db \
  --admin-token "$GRYPHON_ADMIN_TOKEN"
```

For a persistent deployment, mount `/data` as a volume and place the SQLite
database there. The container also exposes `GET /healthz` for orchestration and
load balancer health checks. Use `GET /readyz` for readiness probes.

Recommended production defaults:

- run the relay under a process supervisor or orchestrator
- keep `GRYPHON_ADMIN_TOKEN` in a secret manager
- back up the SQLite database volume
- terminate TLS at a reverse proxy or load balancer
- monitor `/healthz`, `/readyz`, and `/v1/admin/status`

## Development

```sh
gleam run  # Run the project
gleam test # Run the tests
```

Further documentation can be found at <https://hexdocs.pm/gryphon>.

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
gleam run -- server --listen 0.0.0.0:4000 --base-domain example.test --db-path gryphon.db
```

2. Create a tunnel and copy the printed token.

```sh
gleam run -- admin create-tunnel --db-path gryphon.db
```

Example output:

```text
subdomain=demo
token=...
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

Example:

```sh
gleam run -- server --listen 0.0.0.0:4000 --base-domain example.test --db-path gryphon.db
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

Revoke a tunnel:

```sh
gleam run -- admin revoke-tunnel --db-path gryphon.db --subdomain demo
```

## Development

```sh
gleam run  # Run the project
gleam test # Run the tests
```

## Production Deploy

The project ships with a Dockerfile that builds a precompiled Erlang shipment and
runs it without requiring Gleam on the target host.

```sh
docker build -t gryphon .
docker run --rm \
  -p 4000:4000 \
  -v gryphon-data:/data \
  gryphon \
  run server \
  --listen 0.0.0.0:4000 \
  --base-domain example.com \
  --db-path /data/gryphon.db
```

For a persistent deployment, mount `/data` as a volume and place the SQLite
database there. The container also exposes `GET /healthz` for orchestration and
load balancer health checks.

Further documentation can be found at <https://hexdocs.pm/gryphon>.

# CLI DASHBOARD
---

## 1. run gryphon server

```sh

export GRYPHON_ADMIN_TOKEN="dev-token"

gleam run -- server \
  --listen 0.0.0.0:4000 \
  --base-domain re-up.dev \
  --db-path gryphon.db \
  --admin-token "$GRYPHON_ADMIN_TOKEN"

```

## 2. run gryphon dashboard (another terminal)

```sh
export GRYPHON_ADMIN_TOKEN="dev-token"

gleam run -- dashboard \
  --server-url http://127.0.0.1:4000 \
  --admin-token "$GRYPHON_ADMIN_TOKEN"

```

## 3. run gryphon admin to create a tunnel

```sh
gleam run -- admin create-tunnel \
  --db-path cream.db --json

```
  *response*

```json
 // timestamp ⸬ Sat Jun 20, 2026  16:59:53 pm - +08:00
{
  "subdomain": "g0448202b4d",
  "token": "PANm2gjIQbEhI4e0PM-aWDnyXmuHJiymqKbTG_nQCtE",
  "tunnel": {
    "id": "aaIVYgl86QDuAeEQv21Hyg",
    "subdomain": "g0448202b4d",
    "created_at": 1781945194376,
    "revoked_at": null
  }
}

```

## 4. run gryphon agent

```sh
export TUNNEL_TOKEN="PANm2gjIQbEhI4e0PM-aWDnyXmuHJiymqKbTG_nQCtE"

gleam run -- agent \
  --server-url http://127.0.0.1:4000 \
  --token ${TUNNEL_TOKEN} \
  --local-url http://127.0.0.1:6002

```
## 5. curl tunnel

```sh
export SUBDOMAIN=g0448202b4d

# health
curl -fSs \
  --resolve ${SUBDOMAIN}.re-up.dev:4000:127.0.0.1 \
  "http://${SUBDOMAIN}.re-up.dev:4000/health" | jq

# api server stats with auth token
export RAPIDS_TOKEN="ZXlKMGVYQWlPaUpLVjFRaUxDSmhiR2NpT2lKRlV6STFOaUlzSW10cFpDSTZJbUpsWVhKbGNpMWhjR2t0YTJWNUluMC5leUp6ZFdJaU9pSnlZWEJwWkhNdE1ERWlMQ0psZUhBaU9qRTVPVGs1T1RrNU9UY3NJbWxoZENJNk1UY3hNREF3TURBd01Dd2lhWE56SWpvaWNtVXRkWEF1Y0dnaUxDSmhkV1FpT2lKeVlYQnBaSE1pZlEuR0xmWVoxNWI1UkpyRENEWk1xYnNEdlVCbWVSSmJIRmp4WjBBQ29wUjFoYnQzSm80M1A5Sjk1VW1ZX3RnUk9kTjRFM2FmUU1QYm5TZ0h2dE5UNVdYV3cK"

curl -fSs \
  --resolve ${SUBDOMAIN}.re-up.dev:4000:127.0.0.1 \
  "http://${SUBDOMAIN}.re-up.dev:4000/v1/keys/stats" \
  -H "Authorization: Bearer ${RAPIDS_TOKEN}" | jq


```
## 6. open tunnel in browser

```text
http://<subdomain>.<base-domain>/

```





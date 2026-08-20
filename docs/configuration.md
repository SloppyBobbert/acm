# Configuration

Copy the example files before local or production use. Do not put real secrets in the repository. The server reads Clap options from matching environment variables; command-line options take precedence.

## Server and local development

| Variable | Required | Default | Shape and source |
| --- | --- | --- | --- |
| `API_HOSTNAME` | Local script only | `127.0.0.1` | API bind address used by `scripts/dev-local.sh`; not read by server Clap. |
| `HOSTNAME` | No | `127.0.0.1` | Server Clap bind address. Shells commonly predefine it, so pass `--hostname` explicitly. |
| `PORT` | No | `8081` | API TCP port. Server Clap option; `.env.example`; local script. |
| `DATABASE_URL` | Runtime: no | `./db.sqlite` in server, `sqlite://./db.sqlite` in local script | SQLite connection URL. Server Clap option and `.env.example`; use for intentional online SQLx checks against a migrated schema. |
| `RAMIEL_URL` | No | `http://127.0.0.1:8082` | URL of Ramiel. Server Clap option and `.env.example`. |
| `PARALLEL_JOB_COUNT` | No | `1` | Unsigned 8-bit job concurrency. Values must be at least `1`; `0` parses but leaves worker behavior unsupported. |
| `JWT_SECRET` | Yes | none | Signing secret supplied through `.env.example` copy or process environment. |
| `DISCORD_SECRET` | Yes | none | Discord OAuth client secret supplied through `.env.example` copy or process environment. |
| `FRONTEND_ORIGIN` | Yes | none | Exact `http` or `https` origin, without path or query. Used for credentialed CORS. |
| `COOKIE_SECURE` | Yes | none | Boolean. Use `false` only for local HTTP and `true` for production HTTPS. |
| `RAMIEL_HOSTNAME` | Local script only | `127.0.0.1` | Ramiel bind address used by `scripts/dev-local.sh`. |
| `RAMIEL_PORT` | Local script only | `8082` | Ramiel port used by `scripts/dev-local.sh`. |
| `FRONTEND_PORT` | Local script only | `3000` | Next.js dev-server port used by `scripts/dev-local.sh`. |

Ramiel itself accepts `PORT` (default `8082`), `HOSTNAME` (default `127.0.0.1`), and `WASMTIME_CACHE_CONFIG` (default `./wasmtime-cache.toml`). The local script passes Ramiel's bind address and port explicitly. Pass `--hostname` to either service rather than relying on `HOSTNAME` from the shell.

## Frontend

Set these at frontend build/development time in `lilith/.env.local`. They are public browser values, not secrets.

| Variable | Required | Default | Source |
| --- | --- | --- | --- |
| `NEXT_PUBLIC_API_URL` | Yes | Local script: `http://$API_HOSTNAME:$PORT` | `lilith/.env.local.example`; frontend fetch helper. |
| `NEXT_PUBLIC_WS_URL` | Yes | Local script: `ws://$API_HOSTNAME:$PORT/ws` | `lilith/.env.local.example`; dashboard WebSocket client. |

**Current OAuth limitation:** local Discord sign-in redirects to `http://localhost:3000/auth/discord`, so it requires `FRONTEND_ORIGIN=http://localhost:3000`. The example's `127.0.0.1` origin does not support local sign-in.

## Production Compose

Copy `deploy/.env.production.example` to `deploy/.env.production` on the deployment host. Values below marked **supply** must be set by the operator.

| Variable | Required | Default | Shape and source |
| --- | --- | --- | --- |
| `API_DOMAIN` | **Supply** | none | Public API hostname used by Caddy and its health check. |
| `FRONTEND_ORIGIN` | **Supply** | none | Exact HTTPS frontend origin; passed to the server. |
| `JWT_SECRET` | **Supply** | none | Server signing secret. |
| `DISCORD_SECRET` | **Supply** | none | Discord OAuth client secret. |
| `ACM_DATA_DIR` | No | `./.local/production-data` | Host directory mounted at `/var/lib/acm` for SQLite. |
| `PARALLEL_JOB_COUNT` | No | `1` | Passed to the server. |
| `ACM_DOCKER_PLATFORM` | No | `linux/amd64` | Server image build/run platform. Ramiel is fixed to `linux/amd64`. |

Production Compose sets the server bind address, API port, SQLite URL, Ramiel URL, and `COOKIE_SECURE=true` internally. It sets Ramiel's cache configuration internally. Do not add those values to the production env file unless the Compose file is changed.

**Current OAuth limitation:** production Discord sign-in redirects to `https://chicoacm.org/auth/discord`. Arbitrary production frontend origins are not supported for sign-in by configuration alone, even though `FRONTEND_ORIGIN` controls CORS.

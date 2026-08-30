# Configuration

Copy the example files before local or production use. Do not put real secrets in the repository. The server reads Clap options from matching environment variables; command-line options take precedence.

## Server and local development

| Variable | Required | Default | Shape and source |
| --- | --- | --- | --- |
| `API_HOSTNAME` | Local script only | `127.0.0.1` | API bind address used by `scripts/dev-local.sh`; not read by server Clap. |
| `HOSTNAME` | No | `127.0.0.1` | Server Clap bind address. Shells commonly predefine it, so pass `--hostname` explicitly. |
| `PORT` | No | `8081` | API TCP port. Server Clap option; `.env.example`; local script. |
| `DATABASE_URL` | No at runtime; yes for online SQLx checks | `./db.sqlite` in server, `sqlite://./db.sqlite` in local script | SQLite connection URL. The server uses its default when unset; set it to choose another database. Intentional online SQLx checks require a migrated schema. |
| `RAMIEL_URL` | No | `http://127.0.0.1:8082` | URL of Ramiel. Server Clap option and `.env.example`. |
| `PARALLEL_JOB_COUNT` | No | `1` | Unsigned 8-bit job concurrency. Values must be at least `1`; `0` parses but leaves worker behavior unsupported. |
| `JWT_SECRET` | Local script: no; manual server/production: yes | Local script: `dev-only-change-me`; otherwise none | Signing secret. The local default is not production-safe. |
| `DISCORD_SECRET` | Local script: no; manual server/production: yes | Local script: `dev-only-change-me`; otherwise none | Discord OAuth client secret. The local default is not production-safe. |
| `DISCORD_CLIENT_ID` | Local script: no; manual server/production: yes | Local example: `local-discord-client-id`; otherwise none | Discord OAuth client ID. Server environment only. |
| `DISCORD_REDIRECT_URI` | Local script: no; manual server/production: yes | Local example: `http://127.0.0.1:3000/auth/discord`; otherwise none | Uses `FRONTEND_ORIGIN`'s normalized scheme, host, and effective port, with the exact `/auth/discord` path and no credentials, query, or fragment. Register it in Discord. Use HTTPS in production; HTTP is allowed only for insecure localhost development. |
| `FRONTEND_ORIGIN` | Local script: no; manual server/production: yes | Local script: `http://127.0.0.1:3000`; otherwise none | Exact `http` or `https` origin, without path or query. Used for credentialed CORS. |
| `COOKIE_SECURE` | Local script: no; manual server: yes | Local script: `false`; production Compose: `true` | Boolean. Use `false` only for local HTTP and `true` for production HTTPS. |
| `RAMIEL_HOSTNAME` | Local script only | `127.0.0.1` | Ramiel bind address used by `scripts/dev-local.sh`. |
| `RAMIEL_PORT` | Local script only | `8082` | Ramiel port used by `scripts/dev-local.sh`. |
| `FRONTEND_PORT` | Local script only | `3000` | Next.js dev-server port used by `scripts/dev-local.sh`. |

Ramiel itself accepts `PORT` (default `8082`), `HOSTNAME` (default `127.0.0.1`), and `WASMTIME_CACHE_CONFIG` (default `./wasmtime-cache.toml`). The local script passes Ramiel's bind address and port explicitly. Pass `--hostname` to either service rather than relying on `HOSTNAME` from the shell.

The local-script secret defaults exist only for development. Set unique production `JWT_SECRET` and `DISCORD_SECRET` values; never use `dev-only-change-me` outside local development.

## Frontend

Set these at frontend build/development time in `lilith/.env.local`. They are public browser values, not secrets.

| Variable | Required | Default | Source |
| --- | --- | --- | --- |
| `NEXT_PUBLIC_API_URL` | Yes | Local script: `http://$API_HOSTNAME:$PORT` | `lilith/.env.local.example`; frontend fetch helper. |
| `NEXT_PUBLIC_WS_URL` | Yes | Local script: `ws://$API_HOSTNAME:$PORT/ws` | `lilith/.env.local.example`; dashboard WebSocket client. |

Vercel provides `NEXT_PUBLIC_*` values at frontend build time. The frontend navigates to the API start endpoint for Discord sign-in, so it needs only the API and WebSocket URLs. Keep `DISCORD_CLIENT_ID`, `DISCORD_REDIRECT_URI`, and `DISCORD_SECRET` in the server environment. Never put secrets in `NEXT_PUBLIC_*` variables.

## Production Compose

Copy `deploy/.env.production.example` to `deploy/.env.production` on the deployment host. Values below marked **supply** must be set by the operator.

| Variable | Required | Default | Shape and source |
| --- | --- | --- | --- |
| `API_DOMAIN` | **Supply** | none | Public API hostname used by Caddy and its health check. |
| `FRONTEND_ORIGIN` | **Supply** | none | Exact HTTPS frontend origin; passed to the server. |
| `JWT_SECRET` | **Supply** | none | Server signing secret. |
| `DISCORD_CLIENT_ID` | **Supply** | none | Server-only Discord OAuth client ID. |
| `DISCORD_REDIRECT_URI` | **Supply** | none | Uses `FRONTEND_ORIGIN`'s normalized scheme, host, and effective port, with the exact `/auth/discord` path and no credentials, query, or fragment. Register it in Discord. |
| `DISCORD_SECRET` | **Supply** | none | Discord OAuth client secret. |
| `ACM_DATA_DIR` | No | `./.local/production-data` | Host directory mounted at `/var/lib/acm` for SQLite. |
| `PARALLEL_JOB_COUNT` | No | `1` | Passed to the server. |
| `ACM_DOCKER_PLATFORM` | No | `linux/amd64` | Server image build/run platform. Ramiel is fixed to `linux/amd64`. |

The server image command sets the production bind address. Production Compose forwards `DISCORD_CLIENT_ID`, `DISCORD_REDIRECT_URI`, and `DISCORD_SECRET`, and sets the API port, SQLite URL, Ramiel URL, and `COOKIE_SECURE=true` internally; it also sets Ramiel's cache configuration. Do not add those values to the production env file unless the image or Compose file is changed.

Set the Discord server variables on the deployment host. `DISCORD_REDIRECT_URI` must use `FRONTEND_ORIGIN`'s normalized scheme, host, and effective port, with the exact `/auth/discord` path and no credentials, query, or fragment; production must use HTTPS. Use HTTP only for insecure localhost development. Restrict `deploy/.env.production` with `chmod 600`; Docker access can read container environment secrets.

Deploy the frontend and API under one registrable custom domain, such as `app.example.com` and `api.example.com`. Their session cookie uses `SameSite=Lax`; raw unrelated Vercel domains may be blocked by third-party-cookie policies.

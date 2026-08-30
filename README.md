# Chico ACM

Chico ACM is a programming-competition site. The Next.js frontend talks to the Rust API; the API stores application data in SQLite and sends C++ compilation and execution work to Ramiel. Ramiel compiles with the WASI SDK and runs the resulting WebAssembly with Wasmtime.

## Prerequisites

- Rust and Cargo
- Node.js with Corepack (the frontend uses Yarn Classic)
- The WASI SDK at `/opt/wasi-sdk` for a host-native Ramiel process, or Docker
- Docker Compose for the production stack

## Repository map

- `crates/server/` — API, SQLite migrations, job queue, and WebSocket endpoint
- `crates/ramiel/` — C++/WASI compilation and Wasmtime runner
- `lilith/` — Next.js frontend
- `migrations/` — SQLite migrations
- `deploy/` and `compose.production.yml` — production Caddy/API/runner stack
- `scripts/dev-local.sh` — canonical local development entry point

## Local development

Create local environment files from the checked-in examples. Supply development-only secrets; never commit either local file.

```sh
cp .env.example .env
cp lilith/.env.local.example lilith/.env.local
SQLX_OFFLINE=true ./scripts/dev-local.sh
```

By default, the script builds the Rust services, installs frontend dependencies when needed, starts Ramiel on `127.0.0.1:8082`, starts the API on `127.0.0.1:8081`, and runs the frontend on `127.0.0.1:3000`. It writes API and runner logs to `.local/logs/`. Override these defaults with `RAMIEL_HOSTNAME`, `RAMIEL_PORT`, `API_HOSTNAME`, `PORT`, and `FRONTEND_PORT`. The root `.env` sets `DATABASE_URL`, and the script creates its empty SQLite file before Cargo builds. `SQLX_OFFLINE=true` makes Cargo use the checked-in `.sqlx` metadata; the server applies migrations when it starts.

For bounded manual debugging, use three terminals. Do not export the root `.env` into Ramiel:

```sh
# Terminal 1: runner
SQLX_OFFLINE=true cargo run -p ramiel -- --hostname 127.0.0.1 --port 8082

# Terminal 2: API
set -a; . ./.env; set +a
SQLX_OFFLINE=true cargo run -p server -- --hostname 127.0.0.1 --port 8081

# Terminal 3: frontend
cd lilith && corepack yarn dev
```

Set `NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_WS_URL` if they differ from the local defaults. The frontend uses the API URL to start Discord sign-in; keep `DISCORD_CLIENT_ID`, `DISCORD_REDIRECT_URI`, and `DISCORD_SECRET` in the server environment only. `DISCORD_REDIRECT_URI` must use the normalized scheme, host, and effective port of `FRONTEND_ORIGIN`, with the `/auth/discord` path and no credentials, query, or fragment. Register that URI in Discord. Use HTTPS in production; HTTP is allowed only for insecure localhost development.

Check the local services at their default addresses:

```sh
curl --fail http://127.0.0.1:8082/healthz
curl --fail http://127.0.0.1:8081/healthz
SQLX_OFFLINE=true cargo test --workspace
(cd lilith && corepack yarn lint && corepack yarn build)
```

Ordinary Rust checks use checked-in SQLx metadata with `SQLX_OFFLINE=true`. At runtime, the server can use its default `./db.sqlite`; set `DATABASE_URL` to choose another database. `DATABASE_URL` is required for intentional online SQLx checking against a migrated schema; see [testing](docs/testing.md).

## Containers and production

Build production images on the deployment host with `compose.production.yml`; that Compose file is the canonical deployment source. CI publishes server and Ramiel images to GHCR on pushes to `main`, but those images are CI artifacts rather than the documented deployment workflow.

Ramiel uses an amd64 WASI SDK package. On Apple Silicon, set `ACM_DOCKER_PLATFORM=linux/amd64`; for direct local Docker builds, also use `--platform linux/amd64 --provenance=false`.

See [deployment](deploy/README.md) for the production procedure.

## Troubleshooting

- A failing API health check usually means the API is not running or could not start because configuration, SQLite access, or migrations failed. Check `.local/logs/` locally or Compose logs in production.
- Host-native Ramiel requires `/opt/wasi-sdk/bin/clang++`. Use the container when that path is unavailable.
- On Apple Silicon, confirm the amd64 platform setting before building Ramiel.
- `FRONTEND_ORIGIN` must be a complete `http` or `https` origin with no path or query.
- Deploy the frontend and API on a shared registrable custom domain, such as `app.example.com` and `api.example.com`. Their session cookie uses `SameSite=Lax`; unrelated Vercel domains can be blocked by third-party-cookie policies.

## Further documentation

- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Testing](docs/testing.md)
- [Operations](docs/operations.md)
- [Ramiel](crates/ramiel/README.md)

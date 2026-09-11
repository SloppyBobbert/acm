# Chico ACM

Chico ACM is a programming-competition site. The Next.js frontend talks to the Rust API; the API stores application data in SQLite and sends C++ and Rust compilation and execution work to Ramiel. Ramiel compiles with the WASI SDK or Rust toolchain and runs the resulting WebAssembly with Wasmtime. Rust submissions currently support scalar `i32` and `i64` function arguments and results.

## Prerequisites

- Rust and Cargo
- Node.js with Corepack (the frontend uses Yarn Classic)
- A native Linux amd64 runner host with Landlock ABI 3 or later. Use the Ramiel container for its compiler toolchains and isolation helper; see [runner requirements](crates/ramiel/README.md).
- Docker Compose for the production stack

## Repository map

- `crates/server/` — API, SQLite migrations, job queue, and WebSocket endpoint
- `crates/ramiel/` — isolated C++/Rust compilation and Wasmtime runner
- `lilith/` — Next.js frontend
- `migrations/` — SQLite migrations
- `deploy/` and `compose.production.yml` — production Caddy/API/runner stack
- `scripts/dev-local.sh` — canonical local development entry point

## Local development

The full local stack requires a supported Linux amd64 runner host. Apple Silicon/Rosetta cannot run the isolated runner. The frontend and API can run on a Mac, but submission acceptance needs the supported runner. Do not bypass compiler isolation.

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
SQLX_OFFLINE=true cargo test --workspace --locked
(cd lilith && corepack yarn lint && corepack yarn build)
```

Ordinary Rust checks use checked-in SQLx metadata with `SQLX_OFFLINE=true`. At runtime, the server can use its default `./db.sqlite`; set `DATABASE_URL` to choose another database. `DATABASE_URL` is required for intentional online SQLx checking against a migrated schema; see [testing](docs/testing.md).

## Containers and production

Build production images on the deployment host with `compose.production.yml`; that Compose file is the canonical deployment source. `/opt/acm` and `/srv/acm` are recommended checkout locations, not the only locations. Another normalized absolute checkout path is allowed only when every path component is in the production trust lane: root-owned, non-symlinked, and not group- or world-writable. Use the operator toolkit in [deploy/README.md](deploy/README.md): run `sudo deploy/bootstrap-ubuntu.sh --check` before host changes. After bootstrap, use the root-run stable helpers, `sudo /usr/local/libexec/acm/acm-deploy.sh --repository-dir "$(pwd -P)"` and `sudo /usr/local/libexec/acm/acm-db.sh --repository-dir "$(pwd -P)"`, for lifecycle and manual database work. Bootstrap installs no backup scheduler; scheduled backups are deferred. CI validates changes but does not replace a host deployment.

Ramiel requires native Linux amd64 with Landlock ABI 3 or later. Cross-building an amd64 image on Apple Silicon does not make its runner executable under Rosetta. Verify execution on a supported host.

Production Caddy replaces `X-Forwarded-For` with the directly observed client address. The API trusts only Caddy's fixed private Docker address when applying OAuth-start limits. If a CDN or load balancer is added, redesign and configure trusted-proxy handling; do not accept arbitrary forwarded-address chains.

See [deployment](deploy/README.md) for the production procedure.

## Troubleshooting

- A failing API health check usually means the API is not running or could not start because configuration, SQLite access, or migrations failed. Check `.local/logs/` locally or Compose logs in production.
- Host-native Ramiel requires the compiler toolchains and Landlock helper described in [Ramiel](crates/ramiel/README.md). Use its container on a supported host.
- Apple Silicon/Rosetta runner execution is unsupported; setting an amd64 platform does not remove this restriction.
- Open the frontend at the exact configured `FRONTEND_ORIGIN`. `http://localhost:3000` and `http://127.0.0.1:3000` are different browser origins.
- An empty database shows “No featured problem yet.” This differs from an API connection error.
- `FRONTEND_ORIGIN` must be a complete `http` or `https` origin with no path or query.
- Deploy the frontend and API on a shared registrable custom domain, such as `app.example.com` and `api.example.com`. Their session cookie uses `SameSite=Lax`; unrelated Vercel domains can be blocked by third-party-cookie policies.

## Editor code checks

In submission editor **Settings**, enable **Inline code checks** for advisory C++/Rust syntax markers and inline compiler results after Run/Submit. It is off by default and saved locally. While off, no syntax worker or parser assets load and compiler result panels remain available. Syntax checks run locally; they do not send source to the API or replace isolated compilation. See [behavior and limits](docs/editor-diagnostics.md).

## Further documentation

- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Testing](docs/testing.md)
- [Inline editor diagnostics](docs/editor-diagnostics.md)
- [Operations](docs/operations.md)
- [Ramiel](crates/ramiel/README.md)

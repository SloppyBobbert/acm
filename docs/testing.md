# Testing and verification

Run these from the repository root unless noted otherwise.

## Rust

```sh
SQLX_OFFLINE=true cargo check --workspace
SQLX_OFFLINE=true cargo test --workspace
```

Focused checks are available when working on one service:

```sh
SQLX_OFFLINE=true cargo check -p server
SQLX_OFFLINE=true cargo test -p server
SQLX_OFFLINE=true cargo check -p ramiel
SQLX_OFFLINE=true cargo test -p ramiel
```

The checked-in `.sqlx` metadata supports ordinary offline compilation. Use `SQLX_OFFLINE=true` for routine checks and tests. Set `DATABASE_URL` only when running the application or intentionally performing online SQLx checking against a migrated schema; the server applies migrations when it starts.

## Frontend

Use Yarn Classic through Corepack in `lilith/`:

```sh
corepack yarn install --frozen-lockfile
corepack yarn lint
corepack yarn build
```

## Containers and Compose

First copy `deploy/.env.production.example` to `deploy/.env.production` and complete its required values. Then build the production services as Compose builds them:

```sh
docker compose --env-file deploy/.env.production -f compose.production.yml build
docker compose --env-file deploy/.env.production -f compose.production.yml config
```

On Apple Silicon, use `ACM_DOCKER_PLATFORM=linux/amd64`. For an isolated image build, use the matching Dockerfile and platform, for example:

```sh
docker build --platform linux/amd64 --provenance=false -f Dockerfile.ramiel -t acm-ramiel:local .
```

After starting the stack, verify the public API health endpoint and inspect every service's health status as described in [operations](operations.md).

## CI

The current GitHub Actions workflow runs on pushes to `main` and builds/pushes server and Ramiel images to GHCR. It does not run Rust tests, frontend lint/build, Compose validation, or other verification jobs. Run the relevant commands locally before relying on a change.

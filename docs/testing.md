# Testing and verification

Run these from the repository root unless noted otherwise.

## Rust

```sh
SQLX_OFFLINE=true cargo check --workspace --locked
SQLX_OFFLINE=true cargo test --workspace --locked
```

Focused checks are available when working on one service:

```sh
SQLX_OFFLINE=true cargo check -p server --locked
SQLX_OFFLINE=true cargo test -p server --locked
SQLX_OFFLINE=true cargo check -p ramiel --locked
SQLX_OFFLINE=true cargo test -p ramiel --locked
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

On a production host, create `deploy/.env.production` as `root:root` mode `0600` with `sudoedit`, set the required `ACM_DATA_DIR=/var/lib/acm`, and complete its other required values. Use the checked-in example only as a field reference. Then build the production services as Compose builds them:

```sh
sudo docker compose --env-file deploy/.env.production -f compose.production.yml config --quiet
sudo docker compose --env-file deploy/.env.production -f compose.production.yml build
```

`config --quiet` validates the resolved Compose configuration without printing interpolated values, including secrets.

On Apple Silicon, use `ACM_DOCKER_PLATFORM=linux/amd64`. For an isolated image build, use the matching Dockerfile and platform, for example:

```sh
docker build --platform linux/amd64 --provenance=false -f Dockerfile.ramiel -t acm-ramiel:local .
```

After starting the stack, use the bounded production smoke check (use `--resolve` only on the host when testing its local listener):

```sh
sudo /usr/local/libexec/acm/smoke.sh --repository-dir "$(pwd -P)" --resolve
```

## CI

`.github/workflows/validate.yml` runs on pull requests and pushes to `main`. It checks Rust formatting, locked workspace check, Clippy with warnings denied, and locked workspace tests; uses Node 22 to install frontend dependencies with Yarn Classic, then lints and builds; runs Bash syntax and semantic deployment-script tests; and validates resolved production Compose configuration with placeholder environment values. The semantic deployment tests exercise mocked backup and restore contracts, but not a live Docker-backed restore. Ubuntu CI exercises `flock` and `timeout` coverage that is skipped on macOS when those commands are unavailable.

It does not deploy, run containers, exercise live DNS/TLS/OAuth, run the production smoke check, perform a live Docker-backed restore, prove a host is correctly bootstrapped, or provide automated backup supervision. Backups remain manual-only; scheduled backups and a timeout supervisor are deferred. Run the operator checks for those conditions.

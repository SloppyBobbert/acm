# Chico ACM

**A programming-competition site for C++ and Rust practice.**

[![Validation](https://github.com/SloppyBobbert/acm/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/SloppyBobbert/acm/actions/workflows/validate.yml)

[Quick start](#docker-compose) · [Practice problems](docs/local-demo.md) · [Testing](#checks) · [Deployment](deploy/README.md) · [Documentation](#further-documentation)

| Frontend | API | Runner |
| --- | --- | --- |
| Next.js | Rust with SQLite storage | Ramiel compiles C++ and Rust to WebAssembly and executes them with Wasmtime. |

---

## Prerequisites

For the complete local stack, use:

- Docker with Linux containers and Compose 2.39.0 or later.
- Native amd64 or arm64 containers. The Docker Linux kernel must support Landlock ABI 3 or later.
- A development Discord application for sign-in.

Docker supplies the compilers, Rust, Node.js, and frontend dependencies. You do not need host Rust or Node.js for this setup. Ramiel checks filesystem isolation at startup and refuses to run without it.

See [platform support](crates/ramiel/README.md#docker-platform-support) for verified environments and remaining limits.

## Local development

### Docker Compose

Run these commands from the repository root.

1. Register this redirect URI in your development Discord application:

   ```text
   http://127.0.0.1:3000/auth/discord
   ```

2. Create a private root `.env` file. If the file already exists, edit it rather than replace it.

   ```dotenv
   JWT_SECRET=
   DISCORD_CLIENT_ID=
   DISCORD_SECRET=
   ```

   Fill all three values before startup. Use a long, randomly generated value for `JWT_SECRET`. Use your development application's values for the Discord fields. Never commit this file or share its contents.

3. Start the stack:

   ```sh
   docker compose up --build
   ```

4. Open **<http://127.0.0.1:3000>**.

> [!NOTE]
> The first build downloads large toolchains and dependencies. When the code is unchanged, use `docker compose up` for later starts.

After a code change, rebuild the affected image. The frontend runs `next dev` inside its image, without a source bind mount. This is a local development setup, not the production deployment path.

| Service | Local access |
| --- | --- |
| Frontend | `http://127.0.0.1:3000` |
| API health | `http://127.0.0.1:8081/healthz` |
| Ramiel | Private Docker network only. No published host port. |

> [!TIP]
> A new database starts without practice problems. The five [practice fixtures](docs/examples/local-demo/) are not imported automatically. See the [first-run guide](docs/local-demo.md) for administrator setup, sample import, and alternate environment files.

### Check and stop the stack

In another terminal, check service status and the API:

```sh
docker compose ps
curl --fail http://127.0.0.1:8081/healthz
docker compose logs --tail=100 server frontend ramiel
```

To stop the services and retain the database:

```sh
docker compose stop
```

By default, the database uses the named volume `acm-local_local_data`. It is separate from the host's `db.sqlite` file.

> [!CAUTION]
> `docker compose down --volumes` deletes the local Docker database. Do not use it to resolve an ordinary startup failure.

### Host development

For Rust or frontend development outside Docker, use the host launcher. It requires host Rust/Cargo, Node.js with Corepack, and Yarn Classic. Read the [configuration guide](docs/configuration.md) before choosing database and service addresses.

```sh
SQLX_OFFLINE=true ./scripts/dev-local.sh
```

The launcher reads the root `.env` by default. `DEV_ENV_FILE` selects a different private file. It builds the Rust services. If frontend dependencies are missing, it installs them. It writes API and runner logs to `.local/logs/`. The default frontend, API, and runner ports are 3000, 8081, and 8082.

The launcher's Docker fallback for Ramiel is amd64-only. On Apple Silicon, use the native Compose setup instead. `DEV_START_RAMIEL=false` starts only the host frontend and API. Compilation then requires a separately configured supported runner.

Do not export API secrets into a host-native Ramiel process. See [Ramiel setup](crates/ramiel/README.md#running) for its toolchain and isolation requirements.

---

## Checks

With host Rust/Cargo installed, run:

```sh
SQLX_OFFLINE=true cargo check --workspace --locked
SQLX_OFFLINE=true cargo test --workspace --locked
cargo fmt --all -- --check
SQLX_OFFLINE=true cargo clippy --workspace --all-targets --locked -- -D warnings
```

With frontend dependencies installed, run:

```sh
cd lilith
node --test tests/*.test.cjs
corepack yarn lint
corepack yarn build
```

See [testing](docs/testing.md) for Compose checks, isolated recovery tests, and SQLite backup/restore tests. Compiler and recovery tests do not replace a real Discord login and browser Run/Submit check.

## Containers and production

Local `compose.yml` is not a production deployment configuration. Production uses `compose.production.yml` to build Caddy, the API, and Ramiel on the deployment host. The frontend is deployed separately. Production Ramiel remains pinned to native Linux amd64. Both image architectures use WASI SDK 27.

Use the [production operator guide](deploy/README.md). Production requires a trusted root-owned checkout, a private production environment file, and verified backups. Use the installed helpers with an explicit `--repository-dir`. Backups are manual-only. CI does not deploy the application or replace operator checks.

## Troubleshooting

- **Missing environment value:** Fill all three required `.env` values. Do not use production secrets for local development.
- **Port already in use:** Check ports 3000 and 8081 before startup. Do not stop an unrelated service without checking its owner.
- **Ramiel refuses to start:** Check its logs and [platform requirements](crates/ramiel/README.md#docker-platform-support). Do not disable isolation or add privileges.
- **Apple Silicon:** Use native arm64 Compose images. Rosetta runner execution is unsupported.
- **Sign-in fails:** Use `http://127.0.0.1:3000`, not `http://localhost:3000`. Register the exact redirect URI from the [Compose instructions](#docker-compose).
- **No featured problem yet:** The database has no featured problem. This differs from an API connection failure.
- **API health fails:** Check Compose logs. Configuration, SQLite access, or migrations can prevent startup.

## Editor code checks

In the submission editor, open **Settings** and enable **Inline code checks** for optional C++/Rust syntax markers. The setting is off by default and stays in local browser storage. Syntax checks do not send source to the API or replace isolated compilation.

Rust submissions currently support scalar `i32` and `i64` arguments and results. See [Rust submission limits](crates/ramiel/README.md#rust-submissions) and [editor diagnostics](docs/editor-diagnostics.md).

---

## Repository map

| Path | Purpose |
| --- | --- |
| `compose.yml` | Complete local Docker stack |
| `crates/server/` | API, authentication, job queue, and WebSocket endpoint |
| `crates/ramiel/` | Isolated compilers and Wasmtime runner |
| `lilith/` | Next.js frontend |
| `migrations/` | SQLite schema migrations |
| `scripts/dev-local.sh` | Optional host development launcher |
| `deploy/` | Production operator tools and instructions |

## Further documentation

- [First-run guide and practice problems](docs/local-demo.md)
- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Testing](docs/testing.md)
- [Operations](docs/operations.md)
- [Production deployment](deploy/README.md)
- [Ramiel](crates/ramiel/README.md)

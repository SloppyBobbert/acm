# Ramiel

Ramiel is the runner service for Chico ACM. It accepts C++ job requests from the API, compiles C++ to WebAssembly with the WASI SDK, and executes the result with Wasmtime. It also exposes `GET /healthz` for process health checks.

The API uses Ramiel for submissions, custom input, and generated tests. Ramiel's HTTP endpoints are intended for the API, not for public exposure.

## Running

A host-native process requires the WASI SDK compiler at `/opt/wasi-sdk/bin/clang++` and a Wasmtime cache configuration (default `./wasmtime-cache.toml`):

```sh
SQLX_OFFLINE=true cargo run -p ramiel -- --hostname 127.0.0.1 --port 8082
curl --fail http://127.0.0.1:8082/healthz
```

Use `--hostname`, `--port`, and `--wasmtime-cache-config` to override the bind address, port, and cache configuration. Their environment-variable forms are `HOSTNAME`, `PORT`, and `WASMTIME_CACHE_CONFIG`.

The supported production path is the Ramiel container built by `compose.production.yml`. Before using Compose commands, copy `deploy/.env.production.example` to `deploy/.env.production` and complete its required values. The container supplies the WASI SDK, runs as a non-root user, and keeps Ramiel on the internal runner network. The image and Compose service are amd64; use an amd64 host or Docker emulation on Apple Silicon.

## Limits

Ramiel applies request deadlines: 360 seconds for submissions, 120 seconds for test generation, and 60 seconds for custom input. The production container has a read-only root filesystem, a 512 MiB executable `/tmp` tmpfs, 2 CPUs, 2 GiB memory, and a 256-process limit. These limits are operational controls, not a guarantee that untrusted code is safe.

## Focused commands

```sh
SQLX_OFFLINE=true cargo check -p ramiel
SQLX_OFFLINE=true cargo test -p ramiel
docker compose --env-file deploy/.env.production -f compose.production.yml build ramiel
```

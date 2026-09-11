# Ramiel

Ramiel is the runner service for Chico ACM. It compiles C++ and Rust submissions to WebAssembly and executes them with Wasmtime. It also exposes `GET /healthz` for process health checks.

The API uses Ramiel for submissions, custom input, and generated tests. Ramiel's HTTP endpoints are intended for the API, not for public exposure.

## Running

Use the container for local and production runs. A host-native process requires Linux amd64 with Landlock ABI 3 or later, the image's compiler helper at `/usr/local/libexec/acm-compiler-sandbox`, the WASI SDK at `/opt/wasi-sdk/bin/clang++`, and Rust at `/opt/submission-rust`. It also needs a Wasmtime cache configuration (default `./wasmtime-cache.toml`):

```sh
SQLX_OFFLINE=true cargo run -p ramiel -- --hostname 127.0.0.1 --port 8082
curl --fail http://127.0.0.1:8082/healthz
```

Use `--hostname`, `--port`, and `--wasmtime-cache-config` to override the bind address, port, and cache configuration. Their environment-variable forms are `HOSTNAME`, `PORT`, and `WASMTIME_CACHE_CONFIG`.

The supported production path is the Ramiel container built by `compose.production.yml`. Before using Compose commands, copy `deploy/.env.production.example` to `deploy/.env.production` and complete its required values. The container supplies the WASI SDK, runs as a non-root user, and keeps Ramiel on the internal runner network. The image and Compose service require native Linux amd64 with Landlock ABI 3 or later. Docker emulation on Apple Silicon is not supported.

## Rust submissions

The API accepts `language: "cpp"` or `language: "rust"`. Old requests, saved drafts, and database rows default to C++.
Ramiel adds `/run/rust` and `/custom-input/rust`. Reference solutions and `/generate-tests/c++` remain C++.

Rust supports scalar `i32` and `i64` arguments and results. All tests must use one function signature.
Strings, lists, grids, graphs, floats, and other boundary types return an explicit error.
The editor provides a template from the validated test signature. For Add Two Numbers:

```rust
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

The standard library is available inside the function, including local strings and vectors.
The [WASI target](https://doc.rust-lang.org/rustc/platform-support/wasm32-wasip1.html) has platform limits.
The guest has no filesystem access, network access, or application environment variables.
Cargo dependencies and build scripts are not supported.

The container includes Rust 1.92.0 and the `wasm32-wasip1` target at `/opt/submission-rust`.
Ramiel invokes `rustc` directly with fixed flags and a cleared environment.
A generated wrapper exports `acm_entry`. Scalar values pass directly through Wasmtime, without C++ memory layouts.
Compiler diagnostics use the existing error display.

Rust uses the existing deadlines and memory limits. Its fuel budget is four times the adjusted C++ reference budget, with a 100,000-unit minimum.
The existing global fuel cap still applies. This initial allowance is for integer signatures, not a cross-language performance comparison.
C++ fuel budgets remain unchanged.

For real compiler checks, start a restricted local runner container, then run:

```sh
python3 scripts/test-rust-runner.py http://127.0.0.1:8082
# For a container with no published ports:
python3 scripts/test-rust-runner.py docker://container-name
```

This checks the compiler and Wasmtime. It does not replace a logged-in browser test.

## Compiler filesystem isolation

Both compilers run through a small, statically linked helper. The helper applies [Landlock filesystem restrictions](https://docs.kernel.org/userspace-api/landlock.html) before it executes the compiler. The restrictions also apply to linker subprocesses.

A compiler can read its own job directory, toolchain files, and required system libraries. It cannot read reference or peer submission directories. Temporary files stay in the job directory. Compiler environments are cleared. Existing process-group cleanup and deadlines remain active.

Startup requires the native helper to pass a filesystem-denial self-check. Ramiel refuses to start if the helper is missing or cannot enforce Landlock ABI 3 or later. There is no unrestricted fallback. Do not disable seccomp or add container privileges to bypass a failed check.

The build uses the Rust `x86_64-unknown-linux-musl` target for the helper. That build target is not copied into the final image.

Rosetta emulation requires access to per-process files in `/proc`. This policy does not grant that access. The `runner-isolation` CI job runs the real compiler checks on native Ubuntu amd64 instead.

The real runner test script also checks reference-source access, peer-source access, and recovery after denied access. A denied access must report a permission error, not a missing file.

## Limits

Ramiel applies request deadlines: 360 seconds for submissions, 120 seconds for test generation, and 60 seconds for custom input. The production container has a read-only root filesystem, a 512 MiB executable `/tmp` tmpfs, 2 CPUs, 2 GiB memory, and a 256-process limit. These limits are operational controls, not a guarantee that untrusted code is safe.

## Focused commands

```sh
SQLX_OFFLINE=true cargo check -p ramiel
SQLX_OFFLINE=true cargo test -p ramiel
docker compose --env-file deploy/.env.production -f compose.production.yml build ramiel
```

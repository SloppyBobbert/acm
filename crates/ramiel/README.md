# Ramiel

[Chico ACM](../../README.md) / **Runner**

[Setup](#running) · [Platforms](#docker-platform-support) · [Rust submissions](#rust-submissions) · [Isolation](#compiler-filesystem-isolation) · [Limits](#limits)

Ramiel is the runner service for Chico ACM. It compiles C++ and Rust submissions to WebAssembly and executes them with Wasmtime. It also exposes `GET /healthz` for process health checks.

> [!IMPORTANT]
> The API uses Ramiel for submissions, custom input, and generated tests. Ramiel's HTTP endpoints are intended for the API, not for public exposure.

---

## Running

### Local Compose

Use the [complete local stack](../../README.md#docker-compose) for normal development. Run Compose commands from the repository root after you supply the required private environment values:

```sh
docker compose up --build
```

Ramiel has no published host port in this stack. In another terminal, check its health inside the container:

```sh
docker compose exec -T ramiel curl --fail http://127.0.0.1:8082/healthz
```

> [!NOTE]
> A successful health check proves that the process responds. Use the [compiler tests](#rust-submissions) to check compilation and execution.

### Host-native development

A host-native process requires all of these components:

- Native Linux amd64 or arm64 with Landlock ABI 3 or later.
- The static compiler helper at `/usr/local/libexec/acm-compiler-sandbox`.
- WASI SDK 27 at `/opt/wasi-sdk/bin/clang++`.
- Rust 1.92.0 with the `wasm32-wasip1` target at `/opt/submission-rust`.
- A Wasmtime cache configuration. The default path is `./wasmtime-cache.toml`.

Do not export the API's private environment into this process. From the repository root, run:

```sh
SQLX_OFFLINE=true cargo run --locked -p ramiel -- --hostname 127.0.0.1 --port 8082
```

Use `--hostname`, `--port`, and `--wasmtime-cache-config` for the bind address, port, and cache configuration. Their environment forms are `HOSTNAME`, `PORT`, and `WASMTIME_CACHE_CONFIG`. Set the bind address explicitly rather than depend on the shell's `HOSTNAME` value.

### Production

Use the [production operator guide](../../deploy/README.md), not the local Compose configuration. Production Compose keeps Ramiel on a private network and pins its platform to native amd64. The same Dockerfile supplies WASI SDK 27 for local and production builds. CPU emulation is unsupported.

## Docker platform support

Use `docker compose up --build` from the repository root with the required private `.env` values. See [local setup](../../docs/local-demo.md). The image includes checksum-verified WASI SDK 27 and Rust 1.92.0 submission tools for amd64 and arm64. No host compiler installation is required.

| Platform | Verification |
| --- | --- |
| Apple Silicon, Docker Engine 29.4.1, LinuxKit 6.12.76 | Native ARM64 C++/Rust execution, resource limits, file isolation, recovery, and five practice fixtures passed. |
| Native Linux amd64 | Real compiler/isolation tests run in the `runner-isolation` CI matrix. |
| Native Linux arm64 | Real compiler/isolation tests run in the `runner-isolation` CI matrix. |
| Docker Desktop on Windows or Intel Mac | Not yet tested directly. Use Linux containers on a matching CPU architecture. |

All platforms require Landlock ABI 3 or later under Docker's security policy. A kernel version alone does not prove support. The helper must deny access to an existing file before Ramiel can start. An unsupported kernel produces an error, not unrestricted compilation.

These instructions use source builds, not a prebuilt registry release.

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

After the default local Compose runner is healthy, run from the repository root:

```sh
python3 scripts/test-rust-runner.py docker://acm-local-ramiel-1
```

For a custom project name, use the container name from `docker compose ps`. For a supported host-native process, use `http://127.0.0.1:8082` instead of the `docker://` address.

The script checks real C++ and Rust compilation, Wasmtime execution, resource limits, file-access denial, and recovery. It does not replace a logged-in browser test. See [recovery and backup tests](../../docs/testing.md#isolated-failure-recovery) for the separate operational checks.

## Compiler filesystem isolation

Both compilers run through a small, statically linked helper. The helper applies [Landlock filesystem restrictions](https://docs.kernel.org/userspace-api/landlock.html) before it executes the compiler. The restrictions also apply to linker subprocesses.

A compiler can read its own job directory, toolchain files, and required system libraries. It cannot read reference or peer submission directories. Temporary files stay in the job directory. Compiler environments are cleared. Existing process-group cleanup and deadlines remain active.

> [!CAUTION]
> Startup requires the native helper to pass a filesystem-denial self-check. If the helper is missing or cannot enforce Landlock ABI 3 or later, Ramiel refuses to start. There is no unrestricted fallback. Do not disable seccomp or add container privileges to bypass a failed check.

The build selects `x86_64-unknown-linux-musl` or `aarch64-unknown-linux-musl` for the native helper. That build target is not copied into the final image.

Rosetta emulation requires access to per-process files in `/proc`. This policy does not grant that access. The `runner-isolation` CI matrix runs the real compiler checks on native Ubuntu amd64 and arm64 instead.

The real runner test script also checks reference-source access, peer-source access, and recovery after denied access. A denied access must report a permission error, not a missing file.

## Limits

Ramiel applies these request deadlines:

| Request | Deadline |
| --- | ---: |
| Submission | 360 seconds |
| Test generation | 120 seconds |
| Custom input | 60 seconds |

Compose runs the container with a read-only root filesystem and an executable 512 MiB `/tmp` tmpfs. It limits the container to 2 CPUs, 2 GiB memory, and 256 processes. These controls do not guarantee that untrusted code is safe.

## Focused commands

```sh
SQLX_OFFLINE=true cargo check -p ramiel --locked
SQLX_OFFLINE=true cargo test -p ramiel --locked
```

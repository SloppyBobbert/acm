# Testing and verification

Run these from the repository root unless noted otherwise. For a local demo without hosting, use [the demo procedure](local-demo.md) and [its verification record](local-demo-verification.md).

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

### Inline editor diagnostics

```sh
node --test lilith/tests/*.test.cjs
node --test lilith/tests/editor-diagnostics.test.cjs
```

The focused test loads the checked-in actual grammar WASMs, exercises Unicode/CRLF/templates/macros and 50 KiB sources, and checks compiler payloads, persisted defaults, request identities, debounce/concurrency, cleanup and failures. No second unit-test framework or parser npm dependency is required.

For repeatable production-browser checks, use Node 22+ (native WebSocket), Chrome and `agent-browser`. Use a separate frontend port; no database or login is needed because **all API responses in this check are simulated in the browser**. Set the public API URL at build time; missing configuration produces `undefined/...` URLs and is not a valid application setup.

```sh
(cd lilith && NEXT_PUBLIC_API_URL=http://127.0.0.1:8081 NEXT_PUBLIC_WS_URL=ws://127.0.0.1:8081/ws corepack yarn build)
(cd lilith && corepack yarn start -p 3101) # separate terminal
agent-browser --session diagnostics-check open about:blank
node lilith/tests/editor-diagnostics.browser.cjs "$(agent-browser --session diagnostics-check get cdp-url)"
agent-browser --session diagnostics-check close
```

The script attaches CDP to that browser, opens its own page, and runs the production editor with real local syntax workers/grammars. It checks default-off/no parser requests, keyboard toggling, persistence, both languages, Unicode, compiler-marker wiring through Run/Submit, identical-source history restoration, off/on and concurrent-request rejection, missing-worker failure, the 200 KiB limit, navigation, and worker teardown. Screenshots, UI evidence and cold/warm/50 KiB parse timings go under ignored `.local/acceptance/editor-diagnostics/browser/`. Override `DIAGNOSTICS_ORIGIN` and `DIAGNOSTICS_EVIDENCE` if necessary. The browser harness uses React's internal fiber only to locate the actual Monaco model; no test hooks are shipped in production. If React changes, update that harness lookup rather than adding an application backdoor.

This is **not native compiler/browser acceptance**. On a supported native Linux amd64 runner with a test login, separately exercise real Rust/C++ errors and successful compilation through both Run and Submit. Keep that acceptance blocked when the supported host/login is unavailable; never bypass compiler isolation. Asset provenance, versions, licenses and raw sizes are recorded in [the asset manifest](../lilith/public/editor-diagnostics/README.md).

## Local launcher and sample data

```sh
bash -n scripts/dev-local.sh
python3 scripts/tests/test_dev_local.py
SQLX_OFFLINE=true cargo test --locked -p server local_samples_use_existing_creation_and_test_paths
```

The launcher tests use fake processes, not real services. They check origin selection, isolated environment selection, API-only startup, database preservation, and runner cleanup. The sample test uses real migrations and creation/read handlers with an in-memory database and test-only claims. It proves the sample payload format and stored test values, not a real login or compiler run.

## Containers and Compose

On a production host, create `deploy/.env.production` as `root:root` mode `0600` with `sudoedit`, set the required `ACM_DATA_DIR=/var/lib/acm`, and complete its other required values. Use the checked-in example only as a field reference. Then build the production services as Compose builds them:

```sh
sudo docker compose --env-file deploy/.env.production -f compose.production.yml config --quiet
sudo docker compose --env-file deploy/.env.production -f compose.production.yml build
```

`config --quiet` validates the resolved Compose configuration without printing interpolated values, including secrets.

Apple Silicon can cross-build an amd64 image, but cannot run the isolated runner under Rosetta. Execution requires native Linux amd64 with Landlock ABI 3 or later. For an image build only, use the matching Dockerfile and platform:

```sh
docker build --platform linux/amd64 --provenance=false -f Dockerfile.ramiel -t acm-ramiel:local .
```

After starting the stack, use the bounded production smoke check (use `--resolve` only on the host when testing its local listener):

```sh
sudo /usr/local/libexec/acm/smoke.sh --repository-dir "$(pwd -P)" --resolve
```

## CI

`.github/workflows/validate.yml` runs on pull requests and pushes to `main`. It checks Rust formatting, locked workspace check, Clippy with warnings denied, and locked workspace tests; uses Node 22 to install frontend dependencies with Yarn Classic, then lints and builds; runs Bash syntax and semantic deployment-script tests; and validates resolved production Compose configuration with placeholder environment values. The semantic deployment tests exercise mocked backup and restore contracts, but not a live Docker-backed restore. Ubuntu CI exercises `flock` and `timeout` coverage that is skipped on macOS when those commands are unavailable.

The `runner-isolation` CI job runs the real C++ and Rust compilers and Wasmtime in a restricted native Linux amd64 container. It checks reference/peer-file access denial, recovery, execution limits, and missing-helper startup rejection. See [security verification](../specs/security/REVIEW.md).

CI does not deploy, exercise live DNS/TLS/OAuth, run the production smoke check, perform a live Docker-backed restore, prove a host is correctly bootstrapped, or provide automated backup supervision. Backups remain manual-only; scheduled backups and a timeout supervisor are deferred. Run the operator checks for those conditions.

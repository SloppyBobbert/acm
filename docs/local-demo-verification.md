# Local demo verification

Date: 2026-09-11. Base: `0dcc4680fd20037532755a2328cef49514984ab9` (PR #16). Host: macOS arm64, Cargo 1.92.0, Node 24.15.0. No hosting or production data was used.

## Verified locally

| Check | Exact command or action | Result |
| --- | --- | --- |
| Rust formatting | `cargo fmt --all -- --check` | PASS |
| Rust check | `SQLX_OFFLINE=true cargo check --workspace --locked` | PASS |
| First-party Rust lint | `SQLX_OFFLINE=true cargo clippy --workspace --all-targets --locked -- -D warnings` | PASS |
| Workspace tests | `SQLX_OFFLINE=true cargo test --workspace --locked` | PASS: 86 tests, 0 failures |
| Launcher syntax | `bash -n scripts/dev-local.sh` | PASS |
| Launcher regressions | `python3 scripts/tests/test_dev_local.py` | PASS: 11 tests, 0 failures. Service processes are fake in these tests. |
| Frontend tests | `node --test lilith/tests/*.test.cjs` | PASS: 34 tests, 0 failures |
| First-party frontend lint | `(cd lilith && corepack yarn@1.22.22 lint)` | PASS: no ESLint warnings or errors |
| Production frontend build | `(cd lilith && NEXT_PUBLIC_API_URL=http://127.0.0.1:8081 NEXT_PUBLIC_WS_URL=ws://127.0.0.1:8081/ws corepack yarn@1.22.22 build)` | PASS, including type checks |
| Canonical local startup and repeat run | Run `DEV_ENV_FILE="$DEMO_DIR/demo.env" ./scripts/dev-local.sh` using the procedure's new directory; stop and repeat with the same file | PASS: API and frontend HTTP 200 on both runs, real empty-state browser page at port 3000, unchanged database SHA-256 after restart. Runner explicitly skipped. |
| API health | `GET http://127.0.0.1:8081/healthz` against the separate demo database | HTTP 200. **Not runner acceptance.** |
| Empty problem list | `GET /problems` | HTTP 200, `[]` |
| Authentication boundary | Anonymous `GET /user/me`, sample `POST /problems/new`, `POST /run/custom`, and `POST /run/submit` | All HTTP 401: `You must be logged in to do that.` No sample rows created. |
| Credentialed CORS | OPTIONS from `http://127.0.0.1:3101` with the API configured for that origin | Exact origin allowed. `http://localhost:3101` did not receive an allow-origin header. |
| Real browser, no API interception | Production frontend at `http://127.0.0.1:3101` | Home: `No featured problem yet`. Problems navigation: empty list. Missing problem: `Could not load problem`. |
| API stopped, real browser | Stop the API, then reload the home page | `Could not load featured problem. Check that the API is running and reachable from the frontend.` |
| Sample answer functions | Compile both descriptions' C++ and Rust answers with host `clang++` and `rustc`; call each with the three supplied cases | PASS: 12 expected function results. This checks the examples, **not WASI, Ramiel, isolation, or browser submission**. |
| Whitespace | `git diff --check` | PASS |

The new sample test uses real migrations, the existing creation handler, and the existing test-read handler in an in-memory database. It checks denial for logged-out/member claims, two created problems, Rust-compatible signatures, and stored test values. The officer claim exists only in the test. This is not a real login or a real browser import.

The launcher regressions reproduced three failures before the changes: a custom frontend port retained the old origin, an explicit separate environment could not avoid the root `.env`, and an origin mismatch was not rejected. A separate Rust regression reproduced `--cookie-secure false` parsing as `true`. That also caused the real local API to reject its HTTP redirect. The corrected checks pass. An initial formatting check failed before `cargo fmt`; the final formatting check passes.

## Verified with simulated responses

Commands, after the production build:

```sh
(cd lilith && corepack yarn@1.22.22 start -H 127.0.0.1 -p 3101)
agent-browser --session diagnostics-check open about:blank
node lilith/tests/editor-diagnostics.browser.cjs "$(agent-browser --session diagnostics-check get cdp-url)"
```

Result: **PASS**, with zero uncaught browser exceptions. The test uses real Monaco and C++/Rust syntax workers. All problem, user, job, and compiler responses are simulated inside the test only.

Verified:

- Diagnostics default-off, with no syntax-worker or parser-asset requests.
- Keyboard enable/disable, saved setting, and worker cleanup.
- C++/Rust switching, separate language drafts after reload, and navigation between two problem fixtures.
- All four diagnostics/Vim combinations, with a usable editor and footer.
- Real syntax markers, Unicode positions, valid code, and narrow layout.
- Visible HTTP and network failure messages through both Run and Submit.
- Compiler marker limits and result-panel truncation, using simulated compiler errors.
- Rejection of stale results after history restore, off/on, and concurrent Run/Submit.
- Visible missing-worker failure and the 200 KiB source limit.

Raw UI evidence, screenshots, and timing files stay under ignored `.local/acceptance/editor-diagnostics/browser/`. They are not PR artifacts. The test does not establish native compiler acceptance.

## Blocked on login or supported Linux

- **Real sample import:** blocked on a real development Discord login and officer/admin role. The JSON files are ready for the existing creation API. No user was created, no token was manufactured, and no authentication check was bypassed.
- **Populated-database browser demo:** real sample navigation and editing remain unverified until that import. The corresponding editor flows passed with simulated problem data.
- **Logged-in Run/Submit:** successful results and real C++/Rust compiler errors remain unverified. API health and anonymous 401 responses do not satisfy this check.
- **Runner acceptance:** requires native Linux amd64 with Landlock ABI 3 or later and the documented compiler/helper setup. Apple Silicon/Rosetta is not supported acceptance. No isolation or compiler flags were changed.

Use [the demo procedure](local-demo.md) for setup, import, repeat runs, and the remaining acceptance steps. No deployment, purchase, DNS change, production seed, or new dependency is part of this work.

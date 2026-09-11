# Inline editor diagnostics

Status: implemented locally; frontend unit tests, production-browser UI/real grammar checks, lint/build and Rust workspace tests pass. Independent review is required. Native logged-in compiler/browser acceptance remains blocked on a supported Linux host and test login. The approved default-off setting is included; no LSP or autocomplete was added.

## Approved setting

Add one **Inline code checks** toggle to editor settings. Default it to **off**, including for existing saved preferences that have no value for this setting. Save the preference locally using the existing editor preference store.

- **Off:** do not load syntax-check assets, start a syntax worker, or display syntax or compiler inline markers. Existing compiler result panels and Run/Submit behavior remain available.
- **On:** run live syntax checks in the browser and show compiler inline markers after Run/Submit. Actual compilation remains on the backend; no LSP runs on either side.
- Turning the setting off cancels pending checks, terminates the worker, and clears both marker owners. Late responses must not restore markers.
- Turning it back on checks the current source. Do not restore compiler markers from an earlier enabled session; wait for a new Run/Submit result.
- Include the setting's enable-session identity in asynchronous result checks so a response from before an off/on cycle cannot become current again.

## Approved execution plan (retained for traceability)

Run these steps in order. Continue through normal implementation and test corrections without asking for approval at each step. Do not deploy, merge, provision paid resources, or change compiler isolation. Stop only for missing access, a material scope change, or a failed feasibility check that needs a different design.

### 1. Establish the baseline

- Fetch `origin/main` and inspect changes since the plan was written. Start a new `feat/editor-diagnostics` branch from current main; do not reuse the merged Rust feature branch.
- Preserve the pending documentation edits and unrelated local files. Transfer only the intended documentation changes; stop if they conflict with new main changes.
- Read the editor, submission, custom-input, history, and job-result flows before changes. Check all shared editor callers so Markdown and administrative editors retain their current behavior.
- Run the existing frontend tests, lint, and production build. Record existing failures separately from new failures.

Verification, from the repository root:

```sh
node --test lilith/tests/*.test.cjs
(cd lilith && corepack yarn lint && corepack yarn build)
```

### 2. Verify browser parser feasibility

- Confirm current compatible versions, licenses, and delivery of `web-tree-sitter` and the C++/Rust grammar WASM files. Pin runtime and grammar versions together; avoid runtime CDN dependencies.
- Prove that both grammars load in a Web Worker under the existing Next.js 12 production build. Do not upgrade the framework for this feature.
- Check valid submission templates, incomplete functions, missing delimiters, Unicode, CRLF, C++ preprocessor input, and Rust macros.
- Verify the parser's coordinate units and convert them to Monaco's UTF-16 positions. Do not assume byte offsets and editor columns are interchangeable.
- Record grammar download sizes and warm parse timings on the test machine. Check a 50 KiB source fixture. If grammar or build compatibility fails, stop with evidence rather than substituting a full LSP.

Verification: a small browser proof using the actual WASM assets and production build, plus `node --test lilith/tests/editor-diagnostics.test.cjs` for coordinate and fixture assertions. Create that focused test file during this step; do not add a second unit-test framework.

### 3. Add live syntax markers

- Add the approved default-off toggle to the existing editor settings and persisted preference store. Enable diagnostics only for the submission editor; leave Markdown and unrelated editors unchanged.
- Use one worker per active submission editor only while the setting is on. Load the syntax runtime and selected grammar only after enabling. Dispose of workers, parsers, syntax trees, and listeners when no longer needed, including React Strict Mode cleanup.
- Start with a 300 ms typing debounce. Keep at most one in-flight parse and the latest pending source; discard superseded work.
- Attach editor identity, language, and version to requests and results. Ignore stale results after typing, navigation, language changes, or history restoration.
- Use a separate Monaco marker owner for syntax results. Map error and missing nodes to bounded valid ranges; cap results at 100 markers.
- Treat syntax checks as advisory. If source exceeds 200 KiB, assets fail to load, or a parse exceeds a two-second safety deadline, stop the affected check and show a non-blocking status. Editing and Run/Submit must still work. These are initial resource limits, not measured performance claims.

Verification: focused tests for scheduling, range conversion, stale results, cleanup, and failure paths; browser checks for both real grammars, corrections, rapid switching, and zero compiler API requests during typing.

### 4. Add inline compiler diagnostics

- Reuse and validate the existing diagnostic payload rather than introducing a backend endpoint. Gate inline markers on the approved setting; preserve the accessible result panel and plain-text fallback regardless of that setting.
- Connect both `code-runner.tsx` and `input-tester.tsx` results to the submission editor. Trace the actual job result and recent-submission data paths before choosing the smallest shared state change.
- Capture problem, language, submitted source, editor revision, and request identity at dispatch. Only matching current results may change markers. A source-string comparison alone is insufficient if a user edits and then restores the same text.
- Give compiler results a separate marker owner. Clear obsolete markers after edits and matching successful compilation; late failures must not overwrite newer results, including concurrent Run and Submit requests.
- Keep wrapper errors and diagnostics without user-source coordinates in the panel. Check compiler column conventions for Unicode before mapping them; use a line-level marker if a precise column cannot be established safely.
- Do not change compiler flags, submission semantics, security controls, or runtime limits.

Verification: focused tests for malformed payloads, source-less errors, Unicode, successful compilation, both request paths, out-of-order responses, and source/language/history changes. Use browser response fixtures for UI wiring only; label them as simulated rather than real compiler acceptance.

### 5. Verify and review

- Run all frontend tests, lint, production build, and `git diff --check`.
- Run `SQLX_OFFLINE=true cargo test --workspace --locked` to retain the current regression baseline. If any backend change becomes necessary, reassess scope before proceeding.
- Test the production frontend in a browser, not only the development server. Verify asset paths, worker startup, inline messages, keyboard access, narrow screens, history changes, parser failures, and teardown.
- Confirm that typing sends no source to the API. Record asset sizes and parse timings; do not claim a memory reduction without a measurement.
- Review stale-result handling, worker resource bounds, and source privacy. Fix findings and rerun affected checks.
- If a supported native Linux runner and test login are available, verify real Rust/C++ compiler errors through Run and Submit. Otherwise leave that acceptance item explicitly blocked; do not relax isolation or report simulated responses as end-to-end acceptance.

### 6. Finish the handoff

- Update this document to distinguish implemented behavior, tested behavior, and remaining limits. Update the README and testing instructions if commands or dependencies change.
- Record changed files, exact verification commands and outcomes, browser evidence, parser/grammar versions, and any blocked native acceptance.
- Leave the changes ready for review. No deployment or merge is part of this plan.

## Completion rule

The feature implementation is ready for review when local syntax checks, compiler-marker UI tests, failure handling, regression checks, and documentation pass. Full compiler/browser acceptance is complete only after the supported native runner passes the logged-in checks. A blocked external check must remain visible and must not prevent useful local work from finishing.

## Current behavior

The submission editor uses Monaco for C++ and Rust. **Inline code checks** is persisted locally and defaults to off, including old preference stores. Opting in starts one client-only syntax worker; typing is debounced by 300 ms with at most one in-flight parse and one replaceable pending snapshot. Compiler diagnostic panels remain available independently of this setting. Markdown and administrative editors do not opt in.

## Implemented behavior

The following inline behavior applies only while **Inline code checks** is on. It is off by default.

- Run syntax checks in a browser Web Worker with a WebAssembly parser, such as [web-tree-sitter](https://github.com/tree-sitter/tree-sitter/blob/master/lib/binding_web/README.md), and C++/Rust grammars. Load only the selected language grammar.
- Check after a short typing pause. Mark parser errors in the editor without sending source to the API for these checks.
- After Run or Submit, show the existing compiler diagnostics as inline markers. Keep the result panel for accessible messages and compiler errors without a source location. Both paths finish their diagnostic check in `finally`; HTTP, JSON, polling, and network failures retain the prior compiler markers rather than replacing them with no result. Stale completions are still rejected.
- Keep diagnostics status and the Vim bar inside one footer row. The editor retains its `minmax(0,1fr)` row with either setting off or both on.
- Associate results with the submitted source and language. Clear markers when either changes, and ignore late results for an older editor version.
- Keep syntax and compiler markers separate. A parser failure must not prevent editing or submission.

## Limits

Browser syntax checks are advisory. They do not replace compilation, validate test answers, or enforce execution limits. C++ preprocessing and macros can differ from the parser's view. Rust type, trait, and borrow checks still require the compiler.

Compiler checks remain on the isolated runner after Run or Submit. This design adds no persistent rust-analyzer or clangd process and no compiler request on each keystroke. Raw asset sizes and local parse timings are recorded below. Browser memory was not measured; no memory-reduction claim is made. Initialization shows “Loading syntax checks...” and has a ten-second deadline for worker startup and asset loading. A load timeout gets one automatic retry per active diagnostic controller; a second load timeout reports an advisory failure. Once the worker signals that assets are ready, parsing has a separate two-second deadline. Parse timeouts do not retry automatically. Editing or toggling can start another check; editing and Run/Submit remain available throughout.

## Acceptance checks

- Fresh and existing preference stores default to off. The toggle is keyboard-accessible, labeled, and persists across reloads.
- While off, no syntax runtime or grammar assets load, no syntax worker starts, and neither marker owner displays diagnostics. Compiler result panels still work.
- Turning off during a parse or compiler request clears markers and prevents late responses from restoring them, including after an off/on cycle.
- Turning on checks current source; compiler markers require a new Run/Submit request in that enabled session.
- While enabled, invalid C++ and Rust syntax produces inline markers; corrections clear them.
- Syntax checks make no compiler API requests.
- Compiler errors appear at the reported source locations after compilation.
- Errors without a source location remain visible in the result panel.
- Editing, switching languages, or restoring history cannot display stale markers.
- Missing parser assets do not block editing or submission.
- Both language parsers work with the supported submission templates; macro-related limitations are visible to users.

## Local implementation and verification record

- Branch `feat/editor-diagnostics`, base `60224991eace10bdf26e90f703e4e87b67da2106`. Pending documentation edits were preserved. No backend, isolation, dependency, compiler-flag, LSP or autocomplete changes.
- Syntax identity includes editor instance, opt-in session, revision, language, Monaco model version and request sequence. Store mutations invalidate revisions even for identical-source history restoration. Compiler requests share a latest-request sequence across Run and Submit, and capture problem/language/source/revision/session/editor identity at dispatch. Late results cannot restore markers after edits, navigation or off/on cycles. Turning on does not replay old compiler results.
- Separate `submission-syntax` and `submission-compiler` owners; opt-out synchronously clears both, cancels timers and terminates the worker. Worker termination disposes its WASM realm; each parse deletes its tree/cursor, and parser failure deletes the parser. Model disposal is performed with a captured model reference before editor disposal.
- Syntax markers are advisory warnings, capped at 100. String-input Tree-sitter offsets are verified UTF-16 units, then bounded through Monaco positions. Compiler JSON is validated before either panel or marker rendering. Mixed arrays keep valid diagnostics and skip invalid items; wholly invalid responses retain the plain-text fallback. Result panels show at most 500 diagnostics plus an omission note; inline compiler markers have a separate 100-marker limit. Wrapper/source-less errors stay in the panel. Non-ASCII or tab-containing compiler lines use whole-line ranges rather than assuming byte/display-column equivalence.
- Sources above 200 KiB skip syntax parsing. Worker/asset failure, exhausted initialization retry, or a two-second parse timeout reports non-blocking status; editing and Run/Submit remain usable. No compiler/API request is made by syntax checking. The worker loads only the selected language grammar.

### Repeatable checks

See [testing instructions](testing.md#inline-editor-diagnostics) for the exact production-browser command. The checked-in `lilith/tests/editor-diagnostics.test.cjs` uses the existing Node test framework and actual vendored grammars. The production browser script is `lilith/tests/editor-diagnostics.browser.cjs`; its API fixtures are **simulated**, not real compiler acceptance.

Verified locally:

- `node --test lilith/tests/*.test.cjs`: 34 passing tests, including nine focused diagnostic tests (effect setup/cleanup replay and disposed-model cleanup included). Existing Rust draft persistence test now also checks default-off migration.
- `corepack yarn lint` and `corepack yarn build` in `lilith`: pass, Next.js 12.3.7 unchanged. Production browser build explicitly supplies the public API/WS URLs.
- `SQLX_OFFLINE=true cargo test --workspace --locked`: pass; native isolation-only coverage remains gated by the platform as before.
- Production Chrome: actual C++/Rust syntax errors and corrections, UTF-16 Unicode ranges, default-off/no workers or parser asset requests, keyboard Space toggle, persistence across reload, simulated compiler errors via both buttons, wrapper panel retention, same-source history and off/on/concurrent stale-response rejection, missing-worker URL failure, oversized source, navigation and teardown. Narrow-screen screenshots inspected. No uncaught browser exceptions.
- Scoped follow-up: fake-timer tests cover the ten-second initialization deadline, one retry, stale worker replies, and the separate two-second parse deadline. Handler tests cover HTTP, network, JSON, and polling failures. Production-browser checks cover delayed first initialization, all Vim/checks combinations, retained markers after simulated HTTP/network failures, and Run/Submit with checks off. These fixtures do not establish native compiler acceptance.
- `git diff --check`: pass. Independent review remains a separate gate.

### Assets and measured timings

Pinned MIT assets and SHA-256 hashes are in [the asset manifest](../lilith/public/editor-diagnostics/README.md): `web-tree-sitter` 0.27.0, `tree-sitter-cpp` 0.23.4, `tree-sitter-rust` 0.24.0. Both grammar ABIs are 14. Raw runtime JS+WASM is 365,745 bytes; C++ grammar 3,434,931 bytes; Rust grammar 1,102,547 bytes. These are not compressed-transfer or memory measurements.

A separate HTTP check against the local Next production server with `Accept-Encoding: gzip` returned status 200 for all four assets. Encoded response bodies were 31,996 bytes (runtime JS), 83,117 bytes (runtime WASM), 279,175 bytes (C++ grammar), and 115,391 bytes (Rust grammar). These exclude HTTP headers; deployment compression/cache behavior may differ. Evidence: `.local/acceptance/editor-diagnostics/asset-http-sizes.json`.

A local macOS arm64 Chrome 147 production-worker run measured the following parse/traversal times (excludes asset loading; five warm samples, not a performance guarantee):

| Grammar | First parse | Warm samples | 50 KiB comment fixture |
| --- | ---: | --- | ---: |
| C++ | 4.9 ms | 0.1, 0.2, 0.1, 0.1, 0.1 ms | 3.4 ms |
| Rust | 3.7 ms | 0.2, 0.1, 0.2, 0.2, 0.1 ms | 3.1 ms |

Both workers also parsed valid templates with Unicode/CRLF, C++ preprocessor input and Rust macros, reported missing delimiters and incomplete functions, and capped a noisy error fixture at exactly 100 markers. The 50 KiB fixture is a valid function plus a long comment, not a worst-case grammar benchmark. Machine-readable timings and UI evidence are saved under `.local/acceptance/editor-diagnostics/browser/` by the repeatable script.

### Remaining acceptance

Real authenticated Rust/C++ compilation through Run/Submit requires a supported native Linux amd64 runner and test login. Neither is available in this local Apple Silicon environment. That external check is **blocked**, not waived or simulated as complete. No database or real credential was touched, no deployment or merge occurred, and no compiler isolation was relaxed. Advisory parsing cannot check types, borrow rules, linker errors or macro expansion semantics.

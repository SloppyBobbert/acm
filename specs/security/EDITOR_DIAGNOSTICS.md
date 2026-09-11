# Inline diagnostics security review

Scope: `feat/editor-diagnostics`, based on `60224991eace10bdf26e90f703e4e87b67da2106`. This covers the default-off editor feature, not a new review of the compiler sandbox.

Result: no actionable security findings in the reviewed change. This is a source and focused test review, not a penetration test or security certification.

## Boundaries checked

- User source goes to a same-origin browser worker for syntax checks. Typing adds no compiler API request. Compilation remains on the existing explicit Run and Submit paths.
- Worker and grammar URLs are fixed local assets. The language is restricted to C++ or Rust. There is no source-derived URL or shell command.
- The setting defaults to off. Disabled editors start no syntax worker and load no parser assets. No LSP process is added.
- The controller limits source to 200 KiB, results to 100 markers, and pending work to one active request plus the latest pending snapshot. A two-second watchdog terminates unresponsive workers. These limits do not prove a browser memory bound.
- Editor, source revision, language, enabled session, and request identities prevent old results from becoming current markers. Disabling the setting clears markers and terminates the worker.
- Compiler diagnostic data is validated and displayed as text through React or Monaco. Source-less errors remain in the existing panel. The changes add no HTML injection sink, authentication bypass, database operation, or public backend endpoint.
- The independent reviewer compared the four parser assets and three license files byte-for-byte against the pinned official npm packages. Versions, hashes, and licenses are recorded in `lilith/public/editor-diagnostics/README.md`.
- First-party lint checks remain enabled. The ESLint exclusion covers only the unmodified third-party runtime. Local pi-lens settings are not part of this PR.

## Evidence and limits

The independent reviewer ran all 30 frontend tests and checked the asset provenance. The implementation evidence also records passing lint, production build, 85 Rust tests, and production-browser tests using actual Rust/C++ grammars.

Browser compiler responses were simulated. They verify UI wiring and stale-result handling, not native compiler output or authentication. Real authenticated Rust/C++ Run and Submit checks remain pending on a supported Linux amd64 runner.

Syntax parsing is advisory and cannot replace compiler type, borrow, macro, or execution checks. No backend isolation, compiler flags, or execution limits were changed. Browser memory use was not measured. The two-second deadline can reject a slow asset download; that failure must not block editing or submission.

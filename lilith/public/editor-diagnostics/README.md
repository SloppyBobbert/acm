# Pinned browser syntax assets

Only the submission editor's opt-in **Inline code checks** setting loads these assets. No CDN or runtime package installation is used. `worker.js` is first-party code; other JS/WASM files are unmodified published npm assets.

| Package | Version | License | Asset | Bytes | SHA-256 |
| --- | --- | --- | --- | ---: | --- |
| web-tree-sitter | 0.27.0 | MIT | web-tree-sitter.js | 156132 | 7c49e3c1d87e24e0bb4c2def909d17154dfde281f5f8280225450090bb4b8110 |
| web-tree-sitter | 0.27.0 | MIT | web-tree-sitter.wasm | 209613 | c03bccdc3b448a32848f5ae327e209c982bbb0840d43eec8bc2d5759544a1ed3 |
| tree-sitter-cpp | 0.23.4 | MIT | tree-sitter-cpp.wasm | 3434931 | 174eb0deb75b2ec7881bcacda9f995648d8e683956e5c2267e69ab6dc503fcbf |
| tree-sitter-rust | 0.24.0 | MIT | tree-sitter-rust.wasm | 1102547 | f65f354215611fd94ad34134b3427eb3d58cbb745df7b6509ba722184db73d57 |

The adjacent `LICENSE.*` files preserve each package's complete MIT notice. Published sources: [runtime](https://www.npmjs.com/package/web-tree-sitter/v/0.27.0), [C++](https://www.npmjs.com/package/tree-sitter-cpp/v/0.23.4), [Rust](https://www.npmjs.com/package/tree-sitter-rust/v/0.24.0). Both grammar files have ABI 14, supported by this runtime. Versions are pinned as a tested set, not independently floating dependencies.

To reproduce: run `npm pack web-tree-sitter@0.27.0 tree-sitter-cpp@0.23.4 tree-sitter-rust@0.24.0` in a temporary directory, extract each archive separately, and copy the named JS/WASM files from each package root. Copy each package's `LICENSE` under its corresponding `LICENSE.*` name. Verify hashes before replacing assets; run the actual grammar tests and production browser checks after any update. Do not modify vendored JavaScript to satisfy application lint rules.

`node --test lilith/tests/editor-diagnostics.test.cjs` loads these actual assets (no npm parser dependency needed). The tests establish that string-input node offsets are UTF-16 code units, including astral Unicode, and therefore can be converted using Monaco `getPositionAt`. Compiler columns are separate: non-ASCII or tab-containing lines deliberately use whole-line markers.

Raw totals: runtime JS+WASM 365745 bytes; plus selected C++ grammar 3800676 bytes, or selected Rust grammar 1468292 bytes, excluding the small worker. These are uncompressed bytes, not transfer or memory estimates. Only the selected grammar loads in each worker. Terminating the worker releases its parser/WASM realm; completed checks delete trees and cursors explicitly.

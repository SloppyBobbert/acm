# Rust submission security review

Status: Native isolation checks passed. Final browser acceptance is pending before release.
This is a source review with focused runtime checks, not a penetration test.

## Confirmed defect before the isolation fix

**`crates/ramiel/src/runners/rust.rs` — High — Information exposure / judge integrity (CWE-200)**

The compiler shares the runner filesystem. It can read reference files outside its submission directory.
A local test used `include_str!("../reference/implementation.cpp")` in a Rust custom-input submission.
The real compiler accepted it. The guest printed a flag that confirmed access to the synthetic reference source.
No private configuration or real user source was read.

This limitation also exists in `crates/ramiel/src/runners/cplusplus.rs`.
A synthetic C++ submission included its reference source under another function name and returned that function's result.
The real C++ custom-input runner accepted the submission.

The container remains non-root, read-only, network-isolated, and resource-limited.
Those controls do not isolate files between compiler jobs.

The proposed fix now uses one native, statically linked Landlock helper for both compilers.
It grants access to the job directory, toolchains, required libraries, and selected devices only.
It grants no `/proc` access. Startup fails if the helper cannot prove filesystem denial.
The real runner regression script tests reference and peer source access using files that exist.
The reference/peer-file regression passed in native CI for commit `9c5f2c9`.
The reported access defect is closed for the tested cases; this does not prove all possible attacks are blocked.

## Isolation feasibility probe

The current container runs on `6.12.76-linuxkit` as UID 10001, with no effective capabilities, `NoNewPrivs=1`, and seccomp enabled.
The x86-64 Landlock query returned `ENOSYS` (38) under emulation.
A native ARM64 probe returned ABI 6. A native helper also passed a filesystem-denial self-check.
However, Rosetta then required access to `/proc/self/exe`, a public VM setting, and per-process memory maps.
The ARM helper experiment was not sufficient for safe compiler execution. Its extra permissions were removed.
The supported runner now requires native Linux amd64 with Landlock ABI 3 or later.
No seccomp controls were disabled and no container capabilities were added.

## Completed fixes

- Compiler stderr retention is bounded to 1 MiB. The runner continues to drain the pipe.
- Generated Rust wrapper diagnostics no longer claim locations in user source.
- User function names use a restricted identifier format before wrapper generation.
- Compiler arguments are fixed. Rust compilation uses no Cargo invocation.
- Both compiler environments are cleared and temporary files remain in the job directory.
- C++ failures without source locations produce a visible error instead of an empty diagnostic list.

## Verification limits

Two independent reviewers inspected the full feature and then rechecked the corrections.
Both approved the source after the latest-result race, resource-test assertions, wrapper scope, and history labels were corrected.
Local verification passed: 81 Rust tests, Clippy, formatting, frontend tests, frontend lint, and diff checks.
[Native CI run 34629887877](https://github.com/SloppyBobbert/acm/actions/runs/34629887877)
verified real C++/Rust execution, reference/peer-file denial and recovery, and fuel exhaustion.
Memory growth of 256 MiB was allowed; growth of 600 MiB was denied without a guest trap.
Startup without the helper failed with exit code 1. Rust, frontend, shell, and Compose checks also passed.
The logged-in Rust happy path passed before isolation. Final browser checks remain pending until a supported test host is available.

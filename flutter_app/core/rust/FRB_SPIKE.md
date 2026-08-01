# FRB Spike — Wave 1 T1.7 DECISION GATE

**Date:** 2026-08-01
**Status:** ✅ **PASS — proceed with flutter_rust_bridge**

## Goal

Prove that `flutter_rust_bridge` (FRB) 2.12.0-generated Dart code can be **analyzed and
tested under standalone Dart** (no Flutter SDK), so the pure-Dart `core/` package can host
the generated bridge and the full-stack interop test can run here with `dart test`.
Fallback if this failed: raw `#[no_mangle] extern "C"` FFI.

## Version-lock contract (all components pinned to 2.12.0)

| Component | Version | Where pinned |
|---|---|---|
| Codegen CLI | `flutter_rust_bridge_codegen 2.12.0` | `cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked` |
| Rust crate | `flutter_rust_bridge = "=2.12.0"` | `flutter_app/rust/Cargo.toml` |
| Dart package | `flutter_rust_bridge: ^2.12.0` | `flutter_app/core/pubspec.yaml` |

The generated `bridge_generated.rs` / `frb_generated.dart` stamp `codegenVersion = '2.12.0'`
and `rustContentHash`; `RustLib.init(forceSameCodegenVersion: true)` (default) enforces the
match at runtime.

## Exact codegen command (2.12.0 syntax)

```bash
flutter_rust_bridge_codegen generate \
  --rust-input crate::api \
  --rust-root flutter_app/rust \
  --dart-output flutter_app/core/lib/rust \
  --rust-output flutter_app/rust/src/bridge_generated.rs \
  --dart-format-line-length 120
```

Notes on 2.12 CLI (differs from the 2.x-era guess in the task brief):

- `--rust-input` takes the **namespace syntax** (`crate::api`), not a file path — the old
  `rust/src/api/**/*.rs` glob syntax is rejected with a migration error.
- `-d/--dart-output` is a **directory**. The generator emits `frb_generated.dart`,
  `frb_generated.io.dart`, `frb_generated.web.dart` (plus `api.dart`) inside it — not a
  single `bridge_generated.dart`.
- `--rust-output` produces the generated glue module; codegen auto-injects
  `mod bridge_generated;` into `lib.rs` (polisher `add_mod_to_lib`). There is **no**
  `flutter_rust_bridge::frb_generated()` macro in 2.x — that pattern is 1.x-era. The glue
  is `mod <stem>;` + the generated file itself.
- Needs `dart` on PATH for formatting; codegen auto-installs `cargo-expand` on first run.
- Codegen's `flutter pub add` auto-upgrade step fails without Flutter — expected and
  harmless; add the pubspec dependency manually.
- `#[flutter_rust_bridge::frb(sync)]` on `spike_sum` marks it a sync call; the generated
  Dart side uses `handler.executeSync` + SSE codec.

## The GATE — standalone `dart analyze`

`dart pub get` pulled `flutter_rust_bridge 2.12.0` (plus `build_cli_annotations`).

```text
$ dart analyze lib/rust/frb_generated.dart lib/rust/frb_generated.io.dart \
    lib/rust/frb_generated.web.dart lib/rust/api.dart
Analyzing frb_generated.dart, frb_generated.io.dart, frb_generated.web.dart, api.dart...
No issues found!

$ dart analyze   # whole core/ package
Analyzing core...
No issues found!
```

**0 errors, 0 warnings.** The generated bridge imports
`package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart` (+ `_io.dart`), which
is a pure-Dart package — no Flutter SDK required. **GATE PASSED.**

## Dylib init behavior under `dart test` (bonus, passed)

`flutter_app/core/test/spike_frb_test.dart`:

```dart
await RustLib.init(
  externalLibrary:
      ExternalLibrary.open('../rust/target/debug/libqr_transfer_rust.so'),
);
expect(spikeSum(a: 2, b: 3), 5);
```

```text
$ dart test test/spike_frb_test.dart
00:00 +0: RustLib.init loads the debug dylib and spike_sum(2,3) == 5
00:00 +1: All tests passed!
```

So under plain `dart test` the built dylib loads via an explicit
`ExternalLibrary.open(path)` — no env var needed. FRB's default loader config also
supports the debug-unfriendly `ioDirectory` (`../rust/target/release/`) and the
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` env var; for the T4.4 interop test the
explicit-path form (or building a release dylib) is the reliable route.

`cargo build` and `cargo test` in `flutter_app/rust` both pass with the generated
`bridge_generated.rs` in the crate.

## Decision

**Proceed with FRB.** The bridge can live in the standalone-Dart `core/` package, the
generated code analyzes clean, and the dylib loads + runs under `dart test` — which is
exactly the proof the full-stack interop test (T4.4) needs. T2.3 will regenerate with the
real RaptorQ API; the codegen command above is the canonical invocation.

Follow-ups to note for T2.x:

- Pin the codegen CLI via `--locked` in any script/CI; the version contract must stay
  2.12.0 across CLI/crate/Dart pkg (runtime hash check enforces it).
- `--dart-output` emits `frb_generated.dart` (+ platform variants) inside `core/lib/rust/`;
  export the entrypoint (`RustLib`) and `api.dart` functions from the core library as needed.
- Sync vs async: `#[frb(sync)]` keeps the spike thin; decide per-function in T2.1
  (RaptorQ encode/decode are CPU-bound — likely worth async or a worker thread).

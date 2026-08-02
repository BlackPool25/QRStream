# Contributing to QRStream

Thanks for your interest! QRStream is a small, focused project — a few guiding
principles keep it that way.

## Ground rules

- **The wire format is a contract.** The PWA and the Flutter app must remain
  byte-compatible; interop tests (`flutter_app/core/test/interop/`,
  `tests/interop-gen/`) enforce this. Never change the protocol without a
  matching interop proof.
- **Offline-first.** No network, no pairing, no telemetry. New features must
  keep the transfer path socket-free.
- **Test-first.** Every behavior change ships with tests; the suites are
  fast on purpose (`cargo test`, `flutter test`, `dart test`, `npm test`).
- **Small diffs.** Prefer focused changes over large refactors.

## Project layout

```
src/                  PWA (React/TypeScript) — kept as the interop reference
flutter_app/
  lib/                Flutter UI (send/broadcast/receive/settings/shell)
  core/               pure-Dart package qr_transfer_core (protocol, codec, sender, receiver)
  rust/               RaptorQ + zxing-cpp FFI (flutter_rust_bridge 2.12.0)
  test/               Flutter widget tests
packaging/            Linux install.sh, RPM spec, desktop entry
docs/                 architecture, performance, threat model, decisions
```

## Getting started

```bash
# Flutter app
cd flutter_app && flutter pub get && flutter analyze && flutter test
# Core (standalone Dart)
cd flutter_app/core && ~/dart-sdk/bin/dart analyze && ~/dart-sdk/bin/dart test
# Rust
cd flutter_app/rust && cargo build && cargo test
# PWA
npm ci && npm test
```

See `flutter_app/README.md` and `docs/FLUTTER-PLAN.md` for the full build
guide (Android NDK, the Rust cross-compile, the version-locked
flutter_rust_bridge toolchain).

## Pull requests

1. Fork and branch from `main`.
2. Write a failing test first (RED), then the change (GREEN).
3. Run the four suites above; keep them green.
4. Conventional commit messages (`feat:`, `fix:`, `build:`, `docs:`, `test:`)
   — the changelog is generated from them.
5. Open the PR against `main` and describe the scenario the change fixes.

## Code of conduct

Be excellent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Reporting vulnerabilities

See [SECURITY.md](SECURITY.md).

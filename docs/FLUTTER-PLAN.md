# QR Data Transfer — Flutter App: Decisions, Plan & Tooling

> Single source of truth for the native Flutter port (Linux desktop + Android)
> of the QR Data Transfer PWA. Last updated: 2026-08-01.

---

## 1. Product decisions (user-locked)

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | PWA interop | Same architecture/protocol; use a *more efficient* codec where possible | User: "fine as long as both use the same overall architecture and idea; if there is a more efficient option use that, but the working should be the same" |
| D2 | Codec | **Native FFI** — `cberner/raptorq` (Rust) via flutter_rust_bridge | Faster than the PWA's wasm (same engine, native speed); **wire-compatible** with the PWA (4-byte `[SBN u8][ESI BE24]` packet header is identical in crate v1.7 and v2.0.1 — proven) |
| D3 | Build env | User installs Flutter + Android SDK; **verified working here**: Flutter 3.44.8, Android SDK 36, Linux toolchain, GTK3 | `flutter analyze/test/build` all run in this environment |
| D4 | Linux receive | **Send-only on Linux** (QR display); scanning on phones | Avoids the weak Linux camera plugin situation entirely |
| D5 | Save UX | Save → success card with filename → **tap opens with default viewer** | User-specified |
| D6 | Theme | **Brown Material 3**: seed `#6D4C41`, `DynamicSchemeVariant.content` | Research-locked (see §6) |
| D7 | QR decode | Pure-Dart `zxing2` in an isolate pool (2–4) | Native-capture + pure-Dart decode; FFI zxing-cpp upgrade path reserved if device speed is insufficient |
| D8 | Transfer settings | User-selectable per transfer: display fps 12/15/24/30, bytes-per-tile 1/2/2.5 KB, tile layout 1×1/1×3/3×1/2×2/3×3, high-refresh toggle, live KB/s + ETA | Ported from the PWA settings feature |
| D9 | Back-nav + cache (NEW, user request) | Prepared transfer **cached in SendView state**; back from settings does NOT re-chunk; back from broadcast returns to settings tab with the cache intact; "Different file" clears it; only bytesPerTile changes re-encode (mtu change) | User: "when I do back it should not re chunk... a fixed cache is good... if a person goes back while broadcasting it should take them back to the settings tab" |

## 2. Architecture

```
PWA (React, kept as demo)          Flutter native app (new)
  src/protocol/*   wire format  ──▶  core/lib/protocol/*   (pure Dart, byte-compatible)
  src/codec/*      RaptorQ      ──▶  rust/src/api.rs  ── FRB ──▶  core/lib/codec/raptorq_bridge.dart
  src/sender/*     pipeline/pacing  ──▶  core/lib/sender/*  (pure Dart)
  src/receiver/*   frames/stats     ──▶  core/lib/receiver/* (pure Dart)
  src/qr/*         QR encode        ──▶  core/lib/qr/qr_encode.dart (qr ^4.0.0, forced mask 2)
  src/ui/*         PWA views        ──▶  flutter_app/lib/ui/*  (Preact → Flutter widgets)
```

**Wire protocol (unchanged, interop-proof)**: frame = 30-byte header (magic `QRDF`, protoVer 1, type DATA 0x01 / META 0x02, 8-byte sessionId, esi u32 LE, k u32 LE, blockLen u32 LE, totalLen u24 LE ≤ 0xffffff, flags bit0=compressed) + payload + CRC32C(4). Metadata JSON: 13 keys in fixed order. RaptorQ packet = `[SBN u8][ESI BE24] + symbol`, symbol size = mtu − 4, K = ceil(len/(mtu−4)).

**Profiles** (bytes-per-tile): `1k` = V27/symbol1024/mtu1028/budget1465; `2k` = V34/symbol2048/mtu2052/budget2188 (V34, NOT V33 — the V33 forced-mask-2 capacity bug fix); `2.5k` = V40/symbol2560/mtu2564/budget2953.

## 3. Repo layout

```
qr-data-transfer/
  src/  tests/  docs/        (PWA — untouched demo)
  flutter_app/
    pubspec.yaml             (app: qr_transfer_core path + plugins)
    lib/
      main.dart  app.dart    (entry, RustLib.init)
      theme/app_theme.dart + app_theme_constants.dart   (brown M3)
      shell/app_shell.dart   (NavigationBar <600 / Rail ≥600; Linux send-only)
      sender/broadcast_controller.dart + qr_grid_painter.dart
      receiver/camera_service.dart  receiver/saver.dart
      ui/send_view.dart  ui/settings_panel.dart (SettingsPanel + SettingsView)
      ui/broadcast_view.dart  ui/receive_view.dart
    core/                    (pure-Dart package `qr_transfer_core` — standalone dart test)
      lib/protocol/*  lib/codec/*  lib/sender/*  lib/receiver/*  lib/qr/*  lib/rust/bridge_generated.dart
      test/  (incl. fixtures/ from the PWA + interop/interop_test.dart)
    rust/                    (cargo crate `qr_transfer_rust`: raptorq 2.0.1 + frb 2.12.0)
      src/api.rs  src/bridge_generated.rs  tests/interop.rs
    test/                    (Flutter widget tests)
    assets/fonts/            (Fraunces bundled)
```

## 4. Build / verify commands

| Command | What | Runs here? |
|---|---|---|
| `~/dart-sdk/bin/dart test` (in core/) | 245 pure-Dart tests | ✅ |
| `~/dart-sdk/bin/dart analyze` (in core/) | core lint | ✅ |
| `cargo test` (in rust/) | 5 Rust tests incl. PWA-packet interop | ✅ |
| `flutter test` (in flutter_app/) | widget tests | ✅ |
| `flutter analyze` (in flutter_app/) | app lint | ✅ |
| `flutter build linux --debug` | Linux bundle | ✅ (built OK) |
| `flutter build apk` | Android APK | ⚠️ NDK re-download needed (corrupt `28.2.13676358` deleted; AGP will re-fetch) |
| `flutter run -d linux` | run desktop | ✅ |
| PWA: `npx vitest run` / `npx playwright test` | PWA regression | ✅ (kept green) |

## 5. Execution plan + status (waves)

| Wave | Tasks | Status |
|---|---|---|
| W0 | Bootstrap: skeleton, Dart 3.12.2, core pubspec, rust crate, PWA fixtures | ✅ done |
| W1 | Protocol core (crc32c/constants/wire/metadata/sha256/deflate) + FRB spike PASS | ✅ done (80 dart tests) |
| W2 | RaptorQ FFI: api.rs + **PWA-packet interop test** + FRB bridge + facade + fountain interface | ✅ done (5 cargo + 93 dart tests) |
| W3 | Sender: settings/pacing/pipeline/qr_encode + broadcast controller + app scaffold | ✅ done (163 dart + 8 flutter tests) |
| W4 | Receiver: frames/stats/reassembler/**full-stack interop**/decode_pool + camera_service + saver | ✅ done (full-stack interop == original.bin, byte-identical) |
| W5 | UI: brown theme, adaptive shell, send/settings/broadcast/receive views, app entry | ⚠️ **send_view + settings_panel were stubs — REAL versions now written (D9 cache/back-nav included); shell test failing, needs fix + verification** |
| W6 | README, reverse interop, final builds (apk + linux) | ⏳ pending |

## 6. Brown theme (research-locked, do not deviate)

`ColorScheme.fromSeed(seed: #6D4C41, dynamicSchemeVariant: DynamicSchemeVariant.content)`.
Light: primary `#53352B`, surface `#FFF8F6`, primaryContainer `#6D4C41` (== seed), onPrimaryContainer `#EBBEB0`, tertiary `#9A5B12` (amber accent), onTertiary white. Dark: primary `#E9BDAE`, onPrimary `#452920`, surface `#161312`, tertiary `#FFC46B`. Typography: **Fraunces** display/headline (bundled asset, `allowRuntimeFetching:false`), system body. **QR broadcast stage ALWAYS espresso dark** (`#161312`) regardless of app brightness. Constants pinned in `lib/theme/app_theme_constants.dart` + asserted in `test/theme/app_theme_test.dart`. Rationale: `expressive` produces blue (wrong), `vibrant` is loud burnt-orange, `tonalSpot` is terracotta+olive — `content` gives the deep-cocoa/cream/espresso the user asked for.

## 7. Tooling / environment facts

- **Flutter 3.44.8** at `~/development/flutter/bin` (add to PATH: `export PATH="$HOME/development/flutter/bin:$PATH"`).
- **Standalone Dart 3.12.2** at `~/dart-sdk/bin` (core/ tests use this, not Flutter's Dart).
- **Rust/cargo** installed; **flutter_rust_bridge_codegen 2.12.0** (cargo install).
- **Version-lock contract**: `flutter_rust_bridge` Dart pkg, Rust crate, and codegen CLI are ALL `=2.12.0`.
- **Android SDK 36** at `~/Android/Sdk`. **NDK `28.2.13676358` was corrupt (no source.properties) — deleted 2026-08-01; AGP re-downloads on next `flutter build apk`.**
- FFI dylib for tests: `flutter_app/rust/target/debug/libqr_transfer_rust.so` (built by `cargo build`; `RustLib.init` in `ensureRustLib`).
- PWA fixture generator: `tests/interop-gen/gen-fixtures.test.ts` (vitest) writes `flutter_app/core/test/fixtures/*` (committed).
- Subagents used: `task(category=..., load_skills=[...], run_in_background=...)` with Sisyphus-Junior; categories deep/ultrabrain/visual-engineering/unspecified-high/quick/writing.
- **Rule**: subagents must never run `pkill`; kill by PID only.

## 8. Current open work

1. **Fix shell test** (`test/shell/app_shell_test.dart` fails: `SendView` not found — the real SendView replaced the stub; the shell test needs the idle SendView to render or a pump adjustment).
2. **Verify send flow widget test** — write `test/ui/send_view_test.dart` + `test/ui/settings_panel_test.dart` covering: pick→settings→broadcast, back-nav cache (no re-chunk on back), broadcast Stop→settings, bytesPerTile re-prepare only.
3. **Rebuild APK** after NDK re-download; rebuild Linux bundle.
4. **W6**: `flutter_app/README.md` (build steps for the user), reverse-interop (rust dumper → PWA wasm decoder), final verification pass.
5. Keep PWA green (`display.ts` has an uncommitted parallel-task change — do not touch).

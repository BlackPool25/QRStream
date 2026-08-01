# QR Data Transfer — Flutter Port: HANDOFF / Continuation Document

> **READ THIS FIRST.** This is the complete handoff for continuing the native Flutter
> port (Linux desktop + Android) of the QR Data Transfer PWA. The prior orchestrator
> (Sisyphus) built Waves 0–5. Your job: finish Wave 6, fix anything the fresh-eyes
> review finds, and deliver a working app on both platforms.
>
> **Your role is orchestrator, not implementer** — delegate module work to subagents
> (`task(category=..., load_skills=[...], run_in_background=...)`), verify their output
> yourself (never trust a subagent's claim), and commit atomically. **Never run
> `pkill`** — kill by PID only.
>
> **Ask the user questions when a choice genuinely matters** (the user explicitly wants
> to be consulted on implementation choices — see §9). Use the `question` tool for
> multiple-choice decisions.

---

## 0. TL;DR — where we are

| | Status |
|---|---|
| PWA (React, demo) | ✅ Fully working — 384 unit + 11 e2e + 107 soak tests. **Do NOT break it.** One uncommitted change exists (`src/sender/display.ts`) from a parallel task — leave it. |
| Flutter app | ✅ Core protocol + RaptorQ FFI + sender/receiver logic done (245 dart tests). ✅ UI (theme/shell/views) done (36 flutter tests). ✅ Linux build succeeds. ⚠️ Android APK build blocked by **NDK re-download** (corrupt NDK deleted — see §6). ⚠️ Wave 6 (README, reverse-interop, final pass) NOT done. |
| Interop | ✅ **Proven**: the Flutter app's real FFI decoder reassembles PWA-produced packets byte-identical (Rust test + full-stack Dart test). |

---

## 1. What the product is

A fully-offline app that transfers files between devices by streaming a continuous
sequence of live-changing QR codes: the **sender** shows a cycling grid of QR codes on
screen; the **receiver** scans them with a camera, reassembles the file with a RaptorQ
fountain codec, verifies its SHA-256, and saves it. **No network, no pairing, no server,
no encryption** (deliberate — a same-room visual broadcast).

Two implementations share ONE wire protocol:
- **PWA** (React/Vite/TS) — kept as the web demo.
- **Flutter app** (`flutter_app/`) — the native port you're continuing.

The user's core desires: fully local encode/decode (native, better than the PWA's wasm),
brown/warm UI, tap-to-open saved files, per-transfer settings, and sensible
back-navigation that doesn't wastefully re-encode.

---

## 2. User decisions (locked — do not reverse without asking)

| ID | Decision | Detail |
|---|---|---|
| D1 | PWA interop | Same architecture/protocol; a more efficient codec is allowed "as long as the working is the same". Wire-compatible at the packet level (proven). |
| D2 | Codec | **Native FFI** — `cberner/raptorq` (Rust) via flutter_rust_bridge 2.12.0. |
| D3 | Build env | Flutter + Android SDK installed here and working (Flutter 3.44.8, Android SDK 36, Linux toolchain, GTK3). |
| D4 | Linux receive | **Send-only on Linux** (no camera plugin); Receive shows a "scan on your phone" card. |
| D5 | Save UX | Save → success card with filename → **tap opens with the default viewer**. |
| D6 | Theme | **Brown Material 3**: seed `#6D4C41`, `DynamicSchemeVariant.content`. Exact role hexes in §7. |
| D7 | QR decode | Pure-Dart `zxing2` in an isolate pool (2–4). FFI zxing-cpp upgrade path reserved if device speed is insufficient. |
| D8 | Transfer settings | Per-transfer: display fps 12/15/24/30, bytes-per-tile 1/2/2.5 KB, tile layout 1×1/1×3/3×1/2×2/3×3, high-refresh toggle, live KB/s + ETA. |
| D9 | Cache + back-nav | **Prepared transfer cached in SendView state**: back from settings does NOT re-chunk; back from a running broadcast returns to the settings tab with the cache intact; only a bytes-per-tile change re-encodes (mtu change); "Different file" clears the cache. **Implemented + tested.** |

---

## 3. Wire protocol (the interop contract — do not change)

- **Frame** = `Header(30 bytes) + Payload(blockLen) + CRC32C(4 bytes)`, little-endian.
  Header: bytes 0–3 magic `QRDF` (0x51 0x52 0x44 0x46); byte 4 protoVer=1; byte 5 type
  (0x01 DATA / 0x02 META); bytes 6–13 sessionId (8 raw bytes, exposed as 16 hex);
  bytes 14–17 esi u32 LE; bytes 18–21 k u32 LE; bytes 22–25 blockLen u32 LE;
  bytes 26–28 totalLen u24 LE (≤ 0xffffff = 16 MiB); byte 29 flags (bit0 compressed).
- **Metadata JSON** — exactly 13 keys in order: `magic("QRDF-META"), protoVer, sessionId,
  filename, mime, totalSize, compressedSize, compressed, k, symbolSize, mtu, fileSHA256,
  flags`. Rule: `compressed === (compressedSize > 0)`; compressedSize is 0 when
  uncompressed.
- **RaptorQ packet** (the DATA-frame payload) = `[SBN u8][ESI 24-bit BE] + symbol bytes`,
  total length == mtu. Symbol data size = mtu − 4. K = ceil(len/(mtu−4)). **This 4-byte
  header is identical in crate v1.7 (PWA wasm) and v2.0.1 (Flutter native) — the basis
  of interop.**
- **Profiles** (bytes-per-tile): `1k` = V27 / symbol 1024 / mtu 1028 / budget 1465;
  `2k` = **V34** / symbol 2048 / mtu 2052 / budget 2188 (V34, not V33 — V33's forced-mask-2
  capacity 2068 can't hold the 2082-byte frame); `2.5k` = V40 / symbol 2560 / mtu 2564 /
  budget 2953.
- **Metadata re-broadcast** every 32 display ticks → receivers join mid-broadcast.
- Session semantics: a new sessionId resets the receiver (broadcast restart).

---

## 4. Architecture map

```
flutter_app/
  pubspec.yaml              app deps: qr_transfer_core (path), flutter_rust_bridge 2.12.0,
                            camera, media_store_plus, url_launcher, file_selector,
                            wakelock_plus, path_provider, mime, google_fonts, crypto, ...
  lib/
    main.dart  app.dart     entry: WidgetsFlutterBinding + ensureRustLib() + brown MaterialApp
    theme/app_theme.dart + app_theme_constants.dart   (brown M3, espresso QR stage)
    shell/app_shell.dart    NavigationBar <600 / NavigationRail >=600; Linux send-only
    sender/broadcast_controller.dart + qr_grid_painter.dart   (Ticker loop, always-dark stage)
    receiver/camera_service.dart  (Android camera; PlatformUnsupported on Linux)
    receiver/saver.dart     (Android MediaStore + url_launcher open; Linux file_selector + xdg-open)
    ui/send_view.dart       (pick → prepare → settings → broadcast; D9 cache/back-nav)
    ui/settings_panel.dart  (SettingsPanel = send-flow step; SettingsView = nav destination)
    ui/broadcast_view.dart  (dark QR stage, chips, Boost/Stop)
    ui/receive_view.dart    (camera → stats → VERIFIED → save card → tap-to-open)
  core/                     pure-Dart package `qr_transfer_core` (standalone dart test)
    lib/protocol/*          constants, crc32c, wire, metadata, sha256
    lib/codec/*             deflate, fountain/interface.dart, raptorq_bridge.dart (FFI facade)
    lib/rust/bridge_generated.dart   (FRB output — committed)
    lib/sender/*            settings, pacing, pipeline
    lib/receiver/*          frames, stats, reassembler, decode_pool, save_logic
    lib/qr/qr_encode.dart   qr ^4.0.0 forced mask 2, version parity
    test/                   fixtures/ (PWA-generated) + interop/interop_test.dart
  rust/                     cargo crate `qr_transfer_rust`
    src/api.rs  src/bridge_generated.rs  tests/interop.rs
  test/                     Flutter widget tests
  assets/fonts/             Fraunces bundled
```

Key flow (both apps identical):
`file → SHA-256(original) → deflate(skip-if-not-smaller) → RaptorQ encode (mtu from
profile) → DATA frames + META frame → display loop (grid tiles, META every 32 ticks,
adaptive fps, resize-aware)`
→ receiver: `camera → downscale ≤2MP → DecodePool(zxing2 isolates) → FrameBuffer
(dedup by sessionId+esi, session reset, eviction k+0.3k+1000) → Reassembler (one-shot
RaptorQ → inflate → SHA-256 gate → verified only on match) → save`.

---

## 5. Commands (all verified in this environment)

```bash
export PATH="$HOME/development/flutter/bin:$PATH"   # Flutter 3.44.8
# Flutter app
cd flutter_app
flutter analyze            # clean
flutter test               # 36 widget tests — clean
flutter build linux --debug    # ✅ builds
flutter build apk --debug  # ⚠️ NDK re-download required first (see §6)
# Pure-Dart core (standalone Dart, NOT Flutter's)
cd flutter_app/core
~/dart-sdk/bin/dart analyze   # clean
~/dart-sdk/bin/dart test      # 245 tests — clean
# Rust core
cd flutter_app/rust
cargo test                    # 12 tests (7 api + 5 interop) — clean
# PWA (do not break)
cd /home/shreyas/projects/qr-data-transfer
npm test                      # 384 unit
npx playwright test           # 11 e2e (needs `npm run build` first)
SOAK_FULL=1 npx vitest run tests/soak   # 107 soak
```

---

## 6. Environment facts + known issues

- **Flutter 3.44.8** at `~/development/flutter/bin`. **Standalone Dart 3.12.2** at
  `~/dart-sdk/bin` (core tests use this). **Rust/cargo** installed.
  **flutter_rust_bridge_codegen 2.12.0** (cargo install). **Version-lock:**
  `flutter_rust_bridge` Dart pkg = Rust crate = codegen CLI, all `2.12.0`.
- **Android SDK 36** at `~/Android/Sdk`. **The NDK `28.2.13676358` was corrupt (missing
  `source.properties`) and was DELETED.** The Android Gradle Plugin will re-download it
  on the next `flutter build apk` (needs network; ~1 GB). **Do this before reporting the
  APK build.**
- **FFI dylib for tests**: `flutter_app/rust/target/debug/libqr_transfer_rust.so`
  (built by `cargo build`; loaded by `ensureRustLib` in `core/lib/codec/raptorq_bridge.dart`).
  The core interop test + widget tests load it via `RustLib.init`.
- **PWA fixture generator**: `tests/interop-gen/gen-fixtures.test.ts` (vitest) writes
  `flutter_app/core/test/fixtures/*` (committed — the interop contract).
- **Uncommitted PWA change**: `src/sender/display.ts` is modified by a parallel task.
  Do not commit or revert it; leave it out of your commits.
- Subagent rule: `task(category=..., load_skills=[...], run_in_background=...)`
  (Sisyphus-Junior); categories deep/ultrabrain/visual-engineering/unspecified-high/
  quick/writing. **Never pkill.**

---

## 7. UI/UX theme (research-locked — do not deviate without asking the user)

**Brown Material 3.** `ColorScheme.fromSeed(seed: #6D4C41, dynamicSchemeVariant:
DynamicSchemeVariant.content)`.

| Role | Light | Dark |
|---|---|---|
| primary | `#53352B` deep cocoa | `#E9BDAE` warm tan |
| onPrimary | — | `#452920` |
| surface | `#FFF8F6` warm cream | `#161312` espresso |
| primaryContainer | `#6D4C41` (== seed) | `#6D4C41` |
| onPrimaryContainer | `#EBBEB0` | — |
| tertiary (amber accent) | `#9A5B12` (onTertiary white) | `#FFC46B` (onTertiary `#462A00`) |

- **Typography**: Fraunces for display/headline (bundled asset, `allowRuntimeFetching:
  false` — offline-first), system/default for body.
- **QR broadcast stage ALWAYS espresso dark** (`#161312`) regardless of app brightness —
  via `buildQrStageTheme()`; crisp integer px/module (no anti-aliasing blur) — the
  receiver camera depends on it.
- **Layout**: NavigationBar <600dp (phone) / NavigationRail ≥600dp (desktop).
- Constants pinned in `lib/theme/app_theme_constants.dart`, asserted in
  `test/theme/app_theme_test.dart`.
- Rationale (why not alternatives): `expressive` → blue (wrong for brown); `vibrant` →
  loud burnt-orange; `tonalSpot` → terracotta+olive; `content` → the deep-cocoa/cream/
  espresso the user asked for.

**UX contract (D9, already implemented + tested in `send_view.dart` / `send_view_test.dart`):**
- Prepared transfer cached in `SendView` state.
- Back from settings → no re-chunk (fps/layout/high-refresh = estimate-only; only
  bytesPerTile re-encodes).
- Stopping a broadcast → returns to the settings tab with the cache intact.
- "Different file" → clears the cache → back to idle pick screen.
- Refresh-rate probe is lazy (measured on entering settings) and injectable for tests.

---

## 8. Wave status + remaining work

| Wave | Status |
|---|---|
| W0 Bootstrap (skeleton, Dart, core pubspec, rust crate, PWA fixtures) | ✅ |
| W1 Protocol core (crc32c/constants/wire/metadata/sha256/deflate) + FRB spike PASS | ✅ |
| W2 RaptorQ FFI (api.rs, **PWA-packet interop test**, bridge, facade, fountain interface) | ✅ |
| W3 Sender (settings/pacing/pipeline/qr_encode) + broadcast controller + app scaffold | ✅ |
| W4 Receiver (frames/stats/reassembler/**full-stack interop**/decode_pool) + camera + saver | ✅ |
| W5 UI (brown theme, shell, send/settings/broadcast/receive views, app entry) | ✅ (send view + settings panel were stubs; **now real + tested**) |
| **W6 Docs + reverse interop + final pass** | ⏳ **YOUR WORK** |

### W6 tasks (delegate + verify):

1. **Fix Android APK build** (NDK re-download). Then `flutter build apk --debug` and
   `flutter build linux --debug` both green. **Verify the APK file exists and the Linux
   bundle runs.**
2. **Reverse interop proof** (closes Flutter→PWA direction):
   - Add `rust/src/bin/dump_packets.rs` (crate Encoder over a fixture payload → dump
     packets) + a PWA-side vitest `tests/interop-gen/reverse.test.ts` that feeds those
     packets into the PWA's wasm `Decoder` → byte-identical.
   - Verify: `cargo run --bin dump_packets` + `npx vitest run tests/interop-gen/reverse`
     green.
3. **`flutter_app/README.md`** — full build steps for the user (install Flutter, Android
   SDK, GTK deps; `flutter create --platforms=android,linux --org com.qrtransfer .`;
   `cargo install flutter_rust_bridge_codegen` 2.12.0; codegen; `cargo build`; `dart test`
   in core; `flutter run -d linux` / `flutter build apk`). What's verified here vs on-device.
4. **Fresh-eyes review** (mandatory — this work spans 30+ turns): run the Reviewer Gate
   (spawn a high-rigor reviewer with the goal + scenarios + evidence + diff). Fix any
   criterion-cited blockers.
5. **Final verification pass**: full gate (`flutter analyze`, `flutter test`, core
   `dart analyze`+`dart test`, `cargo test`, PWA `npm test` + `npx playwright test`),
   commit, update `docs/FLUTTER-PLAN.md` status table.

### Things to sanity-check (possible loose ends the fresh eyes should verify):

- `send_view.dart`'s `_measureRefreshRate` still exists as a top-level fn but the
  settings panel measures via the injected probe — confirm the real flow measures once
  and the probe doesn't leak timers in tests (send_view_test injects `() async => 60`).
- The `SettingsView` nav destination (app-level settings screen) is a minimal info
  screen — the user may want it to actually edit defaults (ASK the user if this matters).
- `receive_view.dart` is 557 LOC (over the 250 guideline) — the reviewer may flag it for
  a split. Verify before deciding.
- Android `camera` plugin needs the `CAMERA` permission in `AndroidManifest.xml` — check
  the generated android/ scaffolding has it (it's gitignored, generated by flutter create).
- `flutter build apk` may surface Rust NDK cross-compile issues (flutter_rust_bridge
  cargokit handles it, but the NDK must be present) — that's why task 1 is first.

---

## 9. Questions to ask the user (when a real choice arises)

The user explicitly wants to be consulted. Use the `question` tool (multiple-choice).
Known open questions:
1. **SettingsView (nav destination)**: it's currently a static info screen. Should it let
   the user edit *default* transfer settings (persisted), or stay as-is (per-file
   settings only in the send flow)?
2. **Android camera**: accept the `camera` plugin's native preview + zxing2 decode as
   shipped, or invest in the native zxing-cpp FFI upgrade now (only if device testing
   shows decode can't keep up)?
3. **App icon / splash**: any preference for the brown theme, or use the default Flutter
   launcher icon for now?
4. **Reverse-interop scope**: is the Flutter→PWA packet proof (W6 #2) required for
   delivery, or is the PWA→Flutter direction (already proven) sufficient?
5. Anything else the reviewer/you find that changes behavior or UX.

---

## 10. Scenario contract (what "done" means)

For every change, prove with both artifacts (RED→GREEN test output + a real-surface
artifact):

| Scenario | Pass condition | Real surface |
|---|---|---|
| S1 Send flow | pick → settings → broadcast; back from broadcast → settings with cache intact; no re-chunk | `flutter test test/ui/send_view_test.dart` (7 tests) + `flutter run -d linux` manual click-through |
| S2 Full interop | Flutter FFI decodes PWA fixture → byte-identical + verified | `dart test test/interop/interop_test.dart` + `cargo test --test interop` |
| S3 Receive flow | fake camera → stats → VERIFIED → save byte-identical → open | `flutter test test/ui/receive_view_test.dart` (3 fixture sizes) |
| S4 Builds | both `flutter build linux --debug` and `flutter build apk --debug` exit 0 | artifact files exist |
| S5 PWA regression | PWA suites still green | `npm test`, `npx playwright test`, soak |
| S6 Theme | brown scheme roles match §7 | `flutter test test/theme/app_theme_test.dart` |
| S7 D9 cache | back-nav never re-encodes | send_view_test (encoderCreations==1 assertions) |

---

## 11. Final reminders

- **Tests are the floor, real-surface artifacts are the ceiling.** Do not claim "done"
  on a passing test alone — run the app/build and show the artifact.
- **Delegate** module work; **verify** every subagent result yourself; commit atomically
  with conventional messages scoped to `flutter_app/` (never touch PWA `src/`, `tests/`,
  `docs/` except adding the interop-gen test + docs/FLUTTER-PLAN.md updates).
- **Never pkill.** Kill by PID only.
- Keep the PWA green — it's the demo and the interop reference.
- When in doubt about a choice that affects behavior or UX: **ask the user**.

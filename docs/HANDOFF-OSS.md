# Handoff — QRStream OSS launch: README, demos, CI/CD, release

> For the next agent. This documents everything done so far, the exact remaining
> tasks, and the research/decisions needed. Read fully before acting.

## 1. Project state (as of handoff)

**QRStream** — offline-first file transfer between devices as a stream of QR
codes (sender's screen → receiver's camera). PWA (`src/`, React/TS) + native
Flutter app (`flutter_app/`) + Rust core (RaptorQ + zxing-cpp via
flutter_rust_bridge 2.12.0). Wire-compatible between PWA and Flutter.

Repo: `git@github.com:BlackPool25/QRStream.git` (origin set; gh authed as
BlackPool25). Working tree is clean **except** the pre-existing WIP files
(`flutter_app/core/lib/receiver/decode_pool.dart`,
`flutter_app/core/test/receiver/decode_pool_test.dart`, `src/sender/display.ts`)
and `flutter_app/lib/main.dart` (a temporary crash-diagnostic screen — see §6).
**Never** `git add -A`; stage per path.

### Done this session (committed, all tests green)
- Launch crash fixed: R8 keep rules now cover the whole `com.google.mlkit`
  tree (MlKitInitProvider unsatisfied-dependency crash); verified live on a
  connected iQOO via adb.
- ZXing-C++ FFI primary decoder (rust `zxing-cpp 0.5.3`, FRB bridge,
  injectable seam); ML Kit + zxing2 fallbacks. Dual-lane position-stable
  broadcast + 1×2/2×1 layouts. 99 Flutter tests, 283 core, 11+5 cargo, 388
  PWA unit, 11 PWA e2e — all green.
- Branding: QRStream title/icon on Linux; logo-based icon generator
  (`flutter_app/android_templates/icon/generate_logo.dart`, input
  `logo.png`); brand header in the shell (hides while scanning/preparing);
  Boost button removed (wake lock now automatic); real GTK fullscreen on
  Linux via a `qrstream/window` MethodChannel.
- Send MIME now derived from the file extension (`package:mime`) — fixes
  Google Files refusing saved files.
- Packaging: `flutter_app/build/app/outputs/flutter-apk/app-release.apk`
  (37 MB), `dist/qrstream-linux-x64.tar.gz` (11.8 MB), a Fedora RPM
  (`packaging/linux/build-rpm.sh` → built `qrstream-1.0.0-1.fc44.x86_64.rpm`),
  `packaging/linux/install.sh` (sandbox-verified: registers the launcher +
  icon, bundles the Rust codec).

### OSS structure committed (`e8304c8`)
`LICENSE` (MIT — user's choice), `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md`,
`SECURITY.md`, `CODE_OF_CONDUCT.md`, `CHANGELOG.md`, `.github/release.yml`,
`.github/dependabot.yml`, `.github/workflows/ci.yml` (PWA job + a Flutter+Rust
job), `.github/workflows/release.yml` (tag-triggered; builds APK + Linux
tarball, generates release notes, uploads via softprops/action-gh-release).

---

## 2. THE README — your primary task (deep research + build)

**Goal:** replace `README.md` with a production-grade, visually impressive OSS
README that makes people stop, understand, and want to use QRStream.

### 2a. Research (full in-depth — use librarian/explore + web)
Research the best-looking, most effective OSS project READMEs (2024–2026) and
what makes them work. Good starting points already found:
- [kido-luci/flutter-starter-template](https://github.com/kido-luci/flutter-starter-template)
  (2026-era, strong: centered logo, dark/light badge pair, collapsible TOC,
  mermaid architecture, Quick Start with prerequisites table).
- [VeryGoodOpenSource/very_good_core](https://github.com/VeryGoodOpenSource/very_good_core)
  (minimal-but-exemplary Flutter).
- [deveminsahin/starter_app](https://github.com/deveminsahin/starter_app)
  (exact badge set for a Flutter app).
- [daytona.io guide](https://www.daytona.io/dotfiles/how-to-write-4000-stars-github-readme-for-your-project)
  ("front door" theory: header/visuals/quick-start decide everything).
- For a Rust tool, [orhun/git-cliff](https://github.com/orhun/git-cliff) as a
  heavy-docs model.
- Badge sources: shields.io (CI status, license, platforms/versions),
  coverage, Discord/funding optional.
- Structure the README per the canonical order: **logo + one-liner → badge row
  → elevator pitch → features → demo (screenshots/GIF/video) → quick start →
  usage → architecture → testing → contributing → license**.

### 2b. Playwright demo media (REQUIRED — the "wow" factor)
The README needs **real screenshots and ideally a demo GIF/video** of the app
in action. Use Playwright to produce them:
- The PWA is the easiest to drive headlessly. Run the dev server
  (`npm run dev`), then a Playwright script that:
  - Opens SEND, picks a small file (the tests already have fixtures under
    `tests/`), hits Begin broadcast, and screenshots the **QR grid** (also a
    2×2 and a 1×2 dual-lane layout — change settings).
  - Opens RECEIVE with a **virtual camera** (the e2e tests already do this —
    see `tests/e2e/` + `playwright.config.ts`; the virtual camera feeds a
    sender's screen) and screenshots the live stats/VERIFIED overlay mid- and
    post-transfer.
  - Captures the PWA on desktop + a phone-sized viewport (the app is
    responsive).
- Produce: (a) a hero screenshot of the broadcast grid on dark espresso,
  (b) a receive-in-progress shot with the live stats overlay, (c) a verified
  completion shot, (d) optionally an animated GIF of a transfer (e.g.
  `ffmpeg` from a Playwright video recording, or a short screen recording).
- Store them under `docs/screenshots/` and reference them in the README with
  the GitHub blob URLs. Keep files reasonably small (< 500 KB each preferred).
- The Flutter app's look is the brown M3 theme — if you can drive the Linux
  desktop build with a scripted sender/receiver it's a bonus, but the PWA
  visuals are nearly identical and far easier to automate.

### 2c. Ask the user questions (use the question tool) BEFORE writing
At minimum:
1. **README tone/audience:** casual/dev-first vs polished/product-first?
2. **Name/branding in the header:** use the existing `logo.png` + "QRStream"
   wordmark (recommended) — confirm, and whether to add a one-line
   trademark note ("QRStream is a trademark … not covered by the license").
3. **Scope in the README:** focus on the Flutter app + PWA both, or lead with
   the PWA (the primary demo) and mention the native app as a feature?
4. **Badges:** which ones (CI, license MIT, platform Android/Linux, Flutter
   version, coverage)? Any funding/Discord link to add?
5. **Screenshots vs animated GIF** for the demo section (GIF is heavier but
   more impressive).
6. **Stats/honesty:** keep the honest throughput table (recommended — it's a
   differentiator) and the security/threat-model links?
Ask whatever else you discover matters from your research.

### 2d. Write the README
After the answers, write `README.md` incorporating the research + media.
Also keep/refresh: the "Honest throughput expectations" table, the security
model section, the project-structure tree, and add the license + trademark
+ contributing links. Update `flutter_app/README.md`'s branding references
(Boost button text was removed — grep for stale "Boost" mentions).

---

## 3. CI/CD pipelines (after the README)

1. **Verify the workflows**: `.github/workflows/ci.yml` (PWA job + the new
   Flutter+Rust job) and `.github/workflows/release.yml` (tag-triggered). The
   release workflow references `~/dart-sdk/bin/dart` — the standalone Dart SDK
   is NOT on GitHub runners, so the core-tests step must use the Flutter-bundled
   Dart (`flutter test` runs core via the app) or drop `~/dart-sdk` entirely.
   Fix that before push. Also confirm `subosito/flutter-action`'s
   `flutter-version: "3.44.0"` is a real stable version.
2. **Push everything to GitHub** (`git push -u origin main`) — gh is authed.
3. **Create the first release**: tag `v1.0.0` and push the tag, OR run the
   release workflow via `gh workflow run`/`gh release create` with the existing
   artifacts (`app-release.apk`, `dist/qrstream-linux-x64.tar.gz`). Attach
   both + a `SHA256SUMS`. Draft it first, then publish after a smoke test.
4. Optionally add issue templates (bug report / feature request) and a PR
   template under `.github/` — the research found these are part of the
   "professional repo" checklist.

---

## 4. Versioning, releases, and the RPM

### 4a. Versioning strategy
- **SemVer** (`major.minor.patch`), driven by **conventional commits**
  (`feat:` → minor, `fix:` → patch, `BREAKING CHANGE:` → major). The changelog
  is generated from them (`.github/release.yml` label rules + git-cliff or the
  built-in release notes).
- The version lives in **three places that must stay in sync**:
  - `flutter_app/pubspec.yaml` → `version: 1.0.0+1` (Android `versionName`/`versionCode`; the `+1` build number must bump per release).
  - `flutter_app/rust/Cargo.toml` → `version = "0.1.0"` (the Rust crate; bump to match).
  - The Git tag → `v1.0.0`.
- **Version-lock contract (do not break):** flutter_rust_bridge Dart pkg, Rust
  crate, and the `flutter_rust_bridge_codegen` CLI must ALL be `=2.12.0`. Any
  version change is a coordinated change across `pubspec.yaml`, `Cargo.toml`,
  and the codegen invocation — verify `flutter_rust_bridge_codegen --version`
  after upgrades.
- Version bumps go in the same release commit; the release tag is the source
  of truth for what ships.

### 4b. The release process (what a "release" means here)
A release = a SemVer tag + a GitHub Release with build artifacts. The
automated path is `.github/workflows/release.yml` (tag `v*` push → build →
upload). Manual equivalent:
```bash
# 1. bump versions (pubspec, Cargo.toml) + CHANGELOG
git tag v1.0.0
git push origin main --tags
# 2. if the workflow can't run yet, build locally + create the release:
gh release create v1.0.0 \
  flutter_app/build/app/outputs/flutter-apk/app-release.apk \
  dist/qrstream-linux-x64.tar.gz \
  flutter_app/SHA256SUMS \
  --title "QRStream v1.0.0" --generate-notes
```
- **Prereleases**: hyphen tags (`v1.1.0-rc.1`) → the workflow sets
  `prerelease: true` automatically.
- **Artifacts per release**: the Android APK, the Linux portable tarball, the
  **RPM**, and a `SHA256SUMS` file. Draft → smoke-test → publish.
- **Known CI gotcha already noted**: the core-tests step in
  `release.yml`/`ci.yml` references `~/dart-sdk/bin/dart`, which does NOT
  exist on GitHub runners — fix it (use Flutter-bundled Dart or drop the step)
  before the first tag push.

### 4c. The RPM (how it's built, versioned, published)
- Build: `bash packaging/linux/build-rpm.sh` from the repo root. It requires
  `rpm-build` + `patchelf`, and a release bundle built first
  (`cd flutter_app && flutter build linux --release` — which itself needs
  `cd flutter_app/rust && cargo build --release` so the codec ships).
- Versioning: the spec's `Version:` field (currently `1.0.0`) and
  `Release: 1%{?dist}` must match the release tag (`v1.0.0` → Version 1.0.0).
  Bump `Release` (1 → 2 …) when re-releasing the same version. The RPM's
  `%changelog` entry date/version must be updated per release.
- Output: `packaging/linux/rpmbuild/RPMS/x86_64/qrstream-<ver>-<rel>.fc<rel>.<arch>.rpm`
  (the `rpmbuild/` dir is gitignored — it's build output).
- **Publish**: attach the `.rpm` to the GitHub Release alongside the APK and
  tarball (users on Fedora/RHEL can `dnf install ./qrstream-*.rpm`). Optionally
  later add a Copr/packagecloud repo — out of scope now.
- **Contents verified**: the RPM ships `/usr/bin/qrstream` symlink, the bundle
  under `/usr/lib64/qrstream/` (incl. `lib/libqr_transfer_rust.so`), the
  launcher icon, and `qrstream.desktop`; dev-build RUNPATHs are stripped with
  patchelf in `%install`.

### 4d. Post-release hygiene
- Tag the release commit; keep `main` green (the CI badge in the README
  reflects it).
- Update `CHANGELOG.md` (move `[Unreleased]` → the new version) at release
  time — the release workflow generates notes, but the committed CHANGELOG is
  the canonical record.
- Confirm `THIRD_PARTY_NOTICES.md` is current (regen from `flutter pub deps
  --licenses` / `cargo about` if deps changed) before tagging a release.

---

## 5. Other pending items (lower priority — do not block the release)

- **Linux "Different file" freeze** (`flutter_app/lib/ui/send_view.dart`):
  picking a file, going back, picking a *different* file froze on Linux. Isolated
  to the native GTK file dialog (widget + FFI re-prepare tests pass). Suspect:
  `file_selector_linux` second `openFile` under `gtk_native_dialog_run`.
  Options: upgrade `file_selector`/`file_selector_linux`, or a workaround in
  `_realFilePicker`. Not release-blocking (Android + first-pick work).
- **Windows build**: not possible from Linux (Flutter Windows needs a Windows
  host; the camera service is Android-only and the Rust codec needs a Windows
  `.dll` toolchain). If the user wants it, prepare a `windows_templates/` +
  a porting checklist — on a Windows machine.
- **`flutter_app/lib/main.dart`** has an uncommitted diagnostic (renders
  `FATAL: <error>` instead of crashing at launch — added while debugging the
  launch crash, which is now fixed). Decision: keep as hardening (shows errors
  instead of silent crash) or remove for a clean public release. Ask the user.

---

## 6. Key facts the next agent needs

- Commands: `flutter analyze/test` (flutter_app), `~/dart-sdk/bin/dart
  analyze/test` (core), `cargo test` (rust), `npm test` + `npx playwright
  test` (PWA, needs `npm run build` first). All suites currently green.
- Builds: `flutter build apk --release --target-platform android-arm64`
  (artifact at `flutter_app/build/app/outputs/flutter-apk/app-release.apk`),
  `flutter build linux --release` (bundle at
  `flutter_app/build/linux/x64/release/bundle/`; run
  `cd flutter_app/rust && cargo build --release` first so the codec ships).
- Version-lock: flutter_rust_bridge Dart pkg + Rust crate + codegen CLI all
  `=2.12.0`.
- Gotchas: AGP 9 + R8 needs the ML Kit keep rules in
  `flutter_app/android/app/proguard-rules.pro` (committed); never add a
  `proguardFiles(...)` override to the release buildType (it clobbers
  Flutter's rules and strips plugins → launch crash); `android/` and `linux/`
  are gitignored (committed sources of truth live in
  `flutter_app/android_templates/` and `flutter_app/linux_templates/`).
- The 3 WIP files + `main.dart` are uncommitted on purpose — never stage them
  unless the user asks.

## 7. Definition of done

- README rewritten (research-backed, user-approved answers, real Playwright
  screenshots/GIF under `docs/screenshots/`, license + trademark + contributing
  links).
- Workflows fixed + everything pushed to `BlackPool25/QRStream`.
- `v1.0.0` GitHub Release live with the APK + Linux tarball + checksums.
- All suites still green; git status clean apart from the documented WIP.

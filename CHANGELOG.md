# Changelog

All notable changes to QRStream are documented here. This project follows
[Semantic Versioning](https://semver.org/). The changelog is generated from
conventional commits on release.

## [Unreleased]

## [1.0.1] — 2026-08-03

### Added

- Brand header (QRStream logo + wordmark) in the app shell; it hides while
  the camera is scanning or a transfer is preparing.
- Real window fullscreen on Linux desktop (`qrstream/window` channel →
  GTK fullscreen); the Fullscreen button now works on all platforms.
- The screen-awake wake lock is held automatically for the whole broadcast in
  both the Flutter app and the PWA (the manual Boost button was removed).
- 1×2 and 2×1 dual-lane tile layouts; ZXing-C++ native decode as the primary
  receiver scanner (ML Kit fallback); send MIME is derived from the file
  extension.
- Linux packaging: `packaging/linux/install.sh`, a portable tarball, and a
  Fedora/RHEL RPM spec (`build-rpm.sh`).

### Fixed

- The sender QR grid now scales continuously and stays centered: tiles fill
  their cells edge-to-edge (only the QR-spec quiet zone separates them) and
  grow linearly with the window instead of stepping in whole-module jumps, and
  the packed block is centered on the stage so a 2×2 stays together in the
  middle of a tall screen. The chosen layout is kept fixed.
- After receiving a file, "Scan another" stays reachable on short screens —
  the saved card scrolls instead of clipping the button below the fold.
- A completed transfer now survives screen rotation and tab switches, and is
  restored after the app is killed in the background: the receive session
  lives in an app-scoped controller and the saved file's metadata is
  restored via Flutter state restoration.
- Release build crashed at launch on some devices: R8 keep rules now cover
  the whole `com.google.mlkit` tree (MlKitInitProvider dependency graph).
- Release build previously crashed because the Linux bundle lacked the Rust
  codec; it now ships `lib/libqr_transfer_rust.so`.

## [1.0.0] — 2026-08-02

### Added

- First public release: offline QR-stream file transfer (PWA + Flutter app +
  Rust RaptorQ/zxing-cpp core), send + receive, SHA-256 verification,
  MediaStore save and tap-to-open on Android.

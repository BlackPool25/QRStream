#!/usr/bin/env bash
# QRStream — one-line installer for Linux (and WSL).
#
#   curl -fsSL https://raw.githubusercontent.com/BlackPool25/QRStream/main/install.sh | bash
#
# Downloads the latest release bundle from GitHub, verifies its SHA-256 against
# the release's SHA256SUMS, installs into ~/.local/share/qrstream and registers
# a desktop entry (icon + launcher). No root needed.
#
# Windows users: QRStream's native app is Android/Linux today; on Windows use
# the PWA in any modern browser (Chrome/Edge can install it as an app) — see
# the README. If you are on WSL, this script installs the Linux build.

set -euo pipefail

REPO="BlackPool25/QRStream"
APP_NAME="qrstream"
LATEST_URL="https://api.github.com/repos/${REPO}/releases/latest"
TARBALL_URL="https://github.com/${REPO}/releases/latest/download/qrstream-linux-x64.tar.gz"
CHECKSUMS_URL="https://github.com/${REPO}/releases/latest/download/SHA256SUMS"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- preflight ---------------------------------------------------------------
case "$(uname -s)" in
  Linux*) ;;
  Darwin*)
    echo "error: QRStream has no macOS build yet — use the PWA in a browser." >&2
    exit 1
    ;;
  *)
    echo "error: unsupported platform '$(uname -s)'. On Windows, use the PWA; on" >&2
    echo "WSL/Linux run this script." >&2
    exit 1
    ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required (install it, e.g. 'sudo dnf install curl')." >&2
  exit 1
fi

# --- download + verify -------------------------------------------------------
echo "Downloading $APP_NAME (latest release)..."
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/qrstream.tar.gz"
curl -fsSL "$CHECKSUMS_URL" -o "$TMP_DIR/SHA256SUMS"

EXPECTED="$(awk '/qrstream-linux-x64.tar.gz/ {print $1}' "$TMP_DIR/SHA256SUMS")"
if [ -z "$EXPECTED" ]; then
  echo "error: no checksum for qrstream-linux-x64.tar.gz in the release." >&2
  exit 1
fi
ACTUAL="$(sha256sum "$TMP_DIR/qrstream.tar.gz" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "error: checksum mismatch — expected $EXPECTED, got $ACTUAL." >&2
  exit 1
fi
echo "Checksum verified."

# --- install -----------------------------------------------------------------
echo "Installing to $DEST"
mkdir -p "$DEST" "$BIN_DIR" "$APP_DIR" "$ICON_DIR"
tar -xzf "$TMP_DIR/qrstream.tar.gz" -C "$DEST" --strip-components=1

if [ ! -x "$DEST/qr_data_transfer" ]; then
  echo "error: installed bundle is missing the qr_data_transfer binary." >&2
  exit 1
fi
if [ ! -f "$DEST/lib/libqr_transfer_rust.so" ]; then
  echo "error: installed bundle is missing lib/libqr_transfer_rust.so." >&2
  exit 1
fi

ln -sf "$DEST/qr_data_transfer" "$BIN_DIR/$APP_NAME"
cp "$DEST/icon.png" "$ICON_DIR/$APP_NAME.png"

cat > "$APP_DIR/qrstream.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=QRStream
Comment=Offline file transfer as a stream of QR codes
Exec=$DEST/qr_data_transfer
Icon=$APP_NAME
Terminal=false
Categories=Utility;Network;FileTransfer;
EOF
chmod +x "$APP_DIR/qrstream.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t \
    "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" >/dev/null 2>&1 || true
fi

echo ""
echo "Done. Launch QRStream from your app menu, or run: $BIN_DIR/$APP_NAME"
echo "Tip: uninstall with:  rm -rf $DEST $BIN_DIR/$APP_NAME $APP_DIR/qrstream.desktop $ICON_DIR/$APP_NAME.png"

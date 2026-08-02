#!/usr/bin/env bash
# QRStream — portable Linux installer.
#
# Installs the release bundle into ~/.local/share/qrstream and registers a
# desktop entry (icon + launcher) for the current user. No root needed.
#
# Usage:   bash packaging/linux/install.sh
#          (run after `flutter build linux --release` from flutter_app/)

set -euo pipefail

APP_NAME="qrstream"
BUNDLE="build/linux/x64/release/bundle"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"

if [ ! -x "$BUNDLE/qr_data_transfer" ]; then
  echo "error: run 'cd flutter_app && flutter build linux --release' first" >&2
  exit 1
fi

echo "Installing QRStream to $DEST"
mkdir -p "$DEST"
cp -r "$BUNDLE/." "$DEST/"

mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR"
ln -sf "$DEST/qr_data_transfer" "$BIN_DIR/$APP_NAME"
cp "$BUNDLE/icon.png" "$ICON_DIR/$APP_NAME.png"

sed "s|@EXEC_PATH@|$DEST/qr_data_transfer|" packaging/linux/qrstream.desktop \
  > "$APP_DIR/qrstream.desktop"
chmod +x "$APP_DIR/qrstream.desktop"

# Register the launcher with the desktop environment (GNOME/KDE/etc.).
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi
if [ ! -f "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/index.theme" ] \
  && [ -f /usr/share/icons/hicolor/index.theme ]; then
  cp /usr/share/icons/hicolor/index.theme \
    "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/index.theme"
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t \
    "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Done. Launch QRStream from your app menu, or run: $BIN_DIR/$APP_NAME"

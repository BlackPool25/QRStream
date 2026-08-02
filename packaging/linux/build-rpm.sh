#!/usr/bin/env bash
# Build the QRStream RPM from the Flutter Linux release bundle.
#
# Usage (from the repo root):
#   bash packaging/linux/build-rpm.sh
#
# Requires: rpm-build (sudo dnf install -y rpm-build), and a release bundle
# built first (cd flutter_app && flutter build linux --release).
set -euo pipefail

cd "$(dirname "$0")/../.." # repo root

BUNDLE="flutter_app/build/linux/x64/release/bundle"
if [ ! -x "$BUNDLE/qr_data_transfer" ]; then
  echo "error: build the release bundle first: cd flutter_app && flutter build linux --release" >&2
  exit 1
fi

TOPDIR="$(pwd)/packaging/linux/rpmbuild"
rm -rf "$TOPDIR"
mkdir -p "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
# Stage the desktop file so the spec's %{_sourcedir} reference resolves.
cp packaging/linux/qrstream.desktop "$TOPDIR/SOURCES/"

rpmbuild -bb \
  --define "_topdir $TOPDIR" \
  --define "bundle_dir $(pwd)/$BUNDLE" \
  packaging/linux/QRStream.spec

echo "RPM built:"
ls -la "$TOPDIR/RPMS/x86_64/" 2>/dev/null || ls -la "$TOPDIR/RPMS/"*/ 2>/dev/null

# QRStream RPM spec (Fedora / RHEL / openSUSE).
#
# Build (from the repo root — build-rpm.sh wraps this):
#   cd flutter_app && flutter build linux --release
#   rpmbuild -bb --define "_topdir $(pwd)/packaging/linux/rpmbuild" \
#            --define "bundle_dir $(pwd)/flutter_app/build/linux/x64/release/bundle" \
#            packaging/linux/QRStream.spec
#
# Requires: rpm-build, and the GTK3/GLib runtime the Flutter Linux embedder
# links against (glib2, gtk3, libX11, libXext, etc. — pulled in by
# `Requires: gtk3`).

Name:           qrstream
Version:        1.0.0
Release:        1%{?dist}
Summary:        Move files between devices as a stream of QR codes
License:        Proprietary
URL:            https://example.invalid/qrstream
BuildArch:      x86_64

# Flutter plugin .so files and the Rust codec carry a dev-build DT_RUNPATH
# pointing at the machine's build tree; strip it so the shipped libs are
# relocatable (the app loads them from its own lib/ dir, never via rpath).
BuildRequires:  patchelf

Requires:       gtk3
Requires:       libX11
Requires:       libXext
Requires:       fontconfig
Requires:       libc.so.6()(64bit)
Requires:       libgcc_s.so.1()(64bit)
Requires:       libm.so.6()(64bit)

%description
QRStream broadcasts a file from one device's screen as a continuous stream of
QR codes; another device scans it with its camera, reassembles the file with a
RaptorQ fountain codec and verifies its SHA-256. Fully offline: no network, no
pairing. The Linux build is send-only (QR display); receive lives on Android.

%prep
# Nothing to unpack: we package the Flutter release bundle directly.

%build
# The bundle is produced by `flutter build linux --release` (see the header).

%install
install -d %{buildroot}/%{_libdir}/qrstream
install -d %{buildroot}/%{_datadir}/applications
install -d %{buildroot}/%{_datadir}/icons/hicolor/256x256/apps
install -d %{buildroot}/%{_bindir}

# Flutter release bundle: executable + data/ + lib/ + icon.png (built by
# `flutter build linux --release`; passed in via --define bundle_dir).
cp -a %{bundle_dir}/. \
  %{buildroot}/%{_libdir}/qrstream/
ln -s %{_libdir}/qrstream/qr_data_transfer %{buildroot}/%{_bindir}/qrstream

# Strip dev-build RUNPATHs from the bundled shared libraries.
find %{buildroot}/%{_libdir}/qrstream/lib -name '*.so' -print0 \
  | xargs -0 -r -n1 patchelf --remove-rpath

sed "s|@EXEC_PATH@|%{_libdir}/qrstream/qr_data_transfer|" \
  %{_sourcedir}/qrstream.desktop \
  > %{buildroot}/%{_datadir}/applications/qrstream.desktop

cp %{buildroot}/%{_libdir}/qrstream/icon.png \
  %{buildroot}/%{_datadir}/icons/hicolor/256x256/apps/qrstream.png

%files
%{_libdir}/qrstream/
%{_bindir}/qrstream
%{_datadir}/applications/qrstream.desktop
%{_datadir}/icons/hicolor/256x256/apps/qrstream.png

%changelog
* Sat Aug 02 2026 QRStream <noreply@example.invalid> - 1.0.0-1
- Initial QRStream packaging (Flutter Linux release bundle).

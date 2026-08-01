// resolveDylibPath platform resolution — the Android branch returns the bare
// .so name (dlopen searches the APK's lib dir); host branches keep the
// relative cargo target paths used under `dart test`.
import 'dart:io';

import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('on Android resolveDylibPathFor returns the bare .so name', () {
    expect(resolveDylibPathFor(true), 'libqr_transfer_rust.so');
  });

  test('on the host it still resolves the debug/release cargo paths', () {
    final resolved = resolveDylibPathFor(false);
    expect(
      resolved,
      anyOf(
        '../rust/target/debug/libqr_transfer_rust.so',
        '../rust/target/release/libqr_transfer_rust.so',
      ),
    );
  });

  test('resolveDylibPath agrees with resolveDylibPathFor on this host', () {
    expect(resolveDylibPath(), resolveDylibPathFor(Platform.isAndroid));
  });
}

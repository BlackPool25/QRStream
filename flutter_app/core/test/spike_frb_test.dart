import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:qr_transfer_core/rust/api.dart';
import 'package:qr_transfer_core/rust/frb_generated.dart' show RustLib;
import 'package:test/test.dart';

void main() {
  test('RustLib.init loads the debug dylib and spike_sum(2,3) == 5', () async {
    await RustLib.init(
      externalLibrary:
          ExternalLibrary.open('../rust/target/debug/libqr_transfer_rust.so'),
    );

    expect(spikeSum(a: 2, b: 3), 5);
  });
}

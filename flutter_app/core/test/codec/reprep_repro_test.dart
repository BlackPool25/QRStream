// TEMP REPRO: does prepareTransfer → dispose → prepareTransfer(different file)
// hang or crash with the real Rust FFI? Mirrors the send-view "Different file"
// flow after going back.
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';

void main() {
  setUpAll(() => ensureRustLib());

  test('prepare → dispose → prepare different file completes (no hang)', () async {
    final a = Uint8List.fromList(List<int>.generate(200_000, (i) => i & 0xff));
    final b = Uint8List.fromList(List<int>.generate(150_000, (i) => (i * 7) & 0xff));

    final first = await prepareTransfer(
      file: a,
      filename: 'a.bin',
      mime: 'application/octet-stream',
      factory: RustRaptorqFactory(),
    );
    expect(first.info.filename, 'a.bin');
    first.encoder.dispose(); // like _clearCache

    final second = await prepareTransfer(
      file: b,
      filename: 'b.bin',
      mime: 'application/octet-stream',
      factory: RustRaptorqFactory(),
    );
    expect(second.info.filename, 'b.bin');
    expect(second.info.totalSize, 150_000);
    second.encoder.dispose();
  });

  test('prepare three files in a row (repeated different-file) stays fast', () async {
    final factory = RustRaptorqFactory();
    for (var i = 0; i < 3; i++) {
      final bytes = Uint8List.fromList(List<int>.generate(100_000 + i * 1000, (x) => x & 0xff));
      final p = await prepareTransfer(
        file: bytes,
        filename: 'f$i.bin',
        mime: 'application/octet-stream',
        factory: factory,
      );
      p.encoder.dispose();
    }
  });
}

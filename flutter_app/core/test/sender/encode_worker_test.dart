// QrEncodeWorker — background-encode correctness: matrices match the host
// encoder, the per-esi cache returns identical instances on re-request, the
// META slot is cached separately, eviction stays correct, and dispose leaves
// nothing behind.
import 'dart:typed_data';

import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/sender/encode_worker.dart';
import 'package:test/test.dart';

Uint8List _bytes(int seed, [int length = 1004]) => Uint8List.fromList(
  List<int>.generate(length, (i) => (seed * 31 + i) & 0xFF),
);

void main() {
  test('encodes real bytes to matrices identical to the host encoder', () async {
    final worker = QrEncodeWorker(version: 27);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // handshake
    final esis = [0, 1, 2, 3];
    final bytes = [for (final e in esis) _bytes(e)];
    worker.requestFrame(frameIndex: 0, esis: esis, frameBytes: bytes);

    final frames = await _drainUntil(worker, (f) => f.isNotEmpty);
    expect(frames, hasLength(1));
    final tiles = frames.single.$2;
    expect(tiles, hasLength(4));
    for (var i = 0; i < 4; i++) {
      final expected = encodeQrBytes(bytes[i], version: 27);
      expect(tiles[i]!.size, expected.size);
      expect(tiles[i]!.modules, equals(expected.modules));
    }
    worker.dispose();
  });

  test('cache serves the first encode even when re-requested with new bytes', () async {
    final worker = QrEncodeWorker(version: 27);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final firstBytes = _bytes(7);
    worker.requestFrame(frameIndex: 0, esis: [5], frameBytes: [firstBytes]);
    final first = (await _drainUntil(worker, (f) => f.isNotEmpty)).single.$2.single!;
    // Same esi, DIFFERENT bytes: a cache hit must return the first encode,
    // not re-encode the new bytes.
    final secondBytes = _bytes(123);
    worker.requestFrame(frameIndex: 1, esis: [5], frameBytes: [secondBytes]);
    final second = (await _drainUntil(worker, (f) => f.isNotEmpty)).single.$2.single!;
    expect(second.modules, equals(first.modules), reason: 'cache hit serves esi 5');
    expect(
      second.modules,
      isNot(equals(encodeQrBytes(secondBytes, version: 27).modules)),
      reason: 'the new bytes were NOT re-encoded',
    );
    worker.dispose();
  });

  test('meta slot (esi -1) is cached like any other pool index', () async {
    final worker = QrEncodeWorker(version: 27);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final meta = _bytes(99);
    worker.requestFrame(frameIndex: 0, esis: [metaSlotEsi], frameBytes: [meta]);
    final a = (await _drainUntil(worker, (f) => f.isNotEmpty)).single.$2.single!;
    worker.requestFrame(
      frameIndex: 32,
      esis: [metaSlotEsi],
      frameBytes: [_bytes(1)], // different bytes — must be ignored by the cache
    );
    final b = (await _drainUntil(worker, (f) => f.isNotEmpty)).single.$2.single!;
    expect(b.modules, equals(a.modules));
    worker.dispose();
  });

  test('a too-small cache evicts and still encodes correctly', () async {
    // Budget for ~3 matrices at V27 (117² = 13689 B each).
    final worker = QrEncodeWorker(version: 27, maxCacheBytes: 3 * 13689);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final esis = [0, 1, 2, 3];
    final bytes = [for (final e in esis) _bytes(e)];
    worker.requestFrame(frameIndex: 0, esis: esis, frameBytes: bytes);
    final tiles = (await _drainUntil(worker, (f) => f.isNotEmpty)).single.$2;
    for (var i = 0; i < 4; i++) {
      final expected = encodeQrBytes(bytes[i], version: 27);
      expect(tiles[i]!.modules, equals(expected.modules), reason: 'esi $i');
    }
    worker.dispose();
  });

  test('a frame whose payload overflows the version yields a null tile', () async {
    final worker = QrEncodeWorker(version: 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // V1 holds ~17 bytes at ECC-L; 200 bytes must overflow → null tile.
    final tooBig = Uint8List(200);
    worker.requestFrame(frameIndex: 0, esis: [0], frameBytes: [tooBig]);
    final tiles = (await _drainUntil(worker, (f) => f.isNotEmpty)).single.$2;
    expect(tiles.single, isNull);
    worker.dispose();
  });

  test('requests queued before the handshake still get answered', () async {
    final worker = QrEncodeWorker(version: 27);
    // Fire immediately — before the isolate handshake can land.
    worker.requestFrame(frameIndex: 0, esis: [0], frameBytes: [_bytes(1)]);
    final frames = await _drainUntil(
      worker,
      (f) => f.isNotEmpty,
      timeout: const Duration(seconds: 5),
    );
    expect(frames.single.$2.single, isNotNull);
    worker.dispose();
  });
}

/// Polls [worker.drain] until [ready] holds, with a deadline — the isolate
/// replies arrive on the event loop.
Future<List<(int, List<QrMatrix?>)>> _drainUntil(
  QrEncodeWorker worker,
  bool Function(List<(int, List<QrMatrix?>)>) ready, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final drained = worker.drain();
    if (ready(drained)) return drained;
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the encode worker');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

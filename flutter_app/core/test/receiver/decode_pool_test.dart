/// DecodePool tests — TDD RED, written before `lib/receiver/decode_pool.dart`.
///
/// Covers the pool-size math, the synthetic round-trip (encode a real wire
/// frame → QR → rasterize → isolate decode → byte-exact frame bytes, the
/// proof the pool feeds FrameBuffer correct bytes), round-robin dispatch,
/// no-QR robustness, dispose semantics and determinism. Mirrors the PWA's
/// zxing-wasm worker-pool tests.
library;

import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/receiver/decode_pool.dart';
import 'package:test/test.dart';

/// Deterministic synthetic DATA wire frame: seed-derived payload so every
/// frame's bytes are distinct and checkable after a decode round-trip.
Uint8List wireFrame(int seed) {
  final payload = Uint8List.fromList(
    List<int>.generate(128, (i) => (seed * 31 + i * 7) & 0xff),
  );
  return encodeFrame(
    Frame(
      type: typeData,
      sessionId: generateSessionId(),
      esi: seed,
      k: 200,
      totalLen: 0,
      flags: 0,
      payload: payload,
    ),
  );
}

/// Rasterizes [frame] into raw RGB bytes (3 bytes/pixel) at [ppm] pixels per
/// module with a [quiet]-module white quiet zone — the integer-scale
/// rendering the broadcast sender uses, so modules stay at whole-pixel scales.
({Uint8List rgb, int px}) rgbImage(
  Uint8List frame, {
  int ppm = 4,
  int quiet = 4,
  int? version,
}) {
  final qr = encodeQrBytes(frame, version: version);
  final side = qr.size;
  final px = (side + 2 * quiet) * ppm;
  final rgb = Uint8List(px * px * 3);
  for (var y = 0; y < px; y++) {
    for (var x = 0; x < px; x++) {
      final mx = x ~/ ppm - quiet;
      final my = y ~/ ppm - quiet;
      final dark =
          mx >= 0 &&
          mx < side &&
          my >= 0 &&
          my < side &&
          qr.modules[my * side + mx] == 1;
      final offset = (y * px + x) * 3;
      rgb[offset] = dark ? 0 : 255;
      rgb[offset + 1] = dark ? 0 : 255;
      rgb[offset + 2] = dark ? 0 : 255;
    }
  }
  return (rgb: rgb, px: px);
}

void main() {
  group('poolSizeFor', () {
    test('caps at 4 for 8 cores', () {
      expect(poolSizeFor(hardwareConcurrency: 8), 4);
    });

    test('scales as cores minus one, never below 2', () {
      expect(poolSizeFor(hardwareConcurrency: 2), 2);
      expect(poolSizeFor(hardwareConcurrency: 3), 2);
      expect(poolSizeFor(hardwareConcurrency: 5), 4);
    });

    test('floors at 2 for a single core', () {
      expect(poolSizeFor(hardwareConcurrency: 1), 2);
    });

    test('defaults to at least 2', () {
      expect(poolSizeFor(), greaterThanOrEqualTo(2));
    });
  });

  group('DecodePool', () {
    late DecodePool pool;

    setUp(() {
      pool = DecodePool(size: 2);
    });

    tearDown(() {
      pool.dispose();
    });

    test('synthetic wire frame round-trips byte-exact', () async {
      final frame = wireFrame(0);
      final image = rgbImage(frame);

      final results = await pool.decode(image.rgb, image.px, image.px);

      expect(results, hasLength(1));
      expect(results.single.bytes, equals(frame));
    });

    test('a grid-profile V27 wire frame round-trips byte-exact', () async {
      final payload = Uint8List.fromList(
        List<int>.generate(1000, (i) => (i * 13 + 3) & 0xff),
      );
      final frame = encodeFrame(
        Frame(
          type: typeData,
          sessionId: generateSessionId(),
          esi: 0,
          k: 500,
          totalLen: 0,
          flags: 0,
          payload: payload,
        ),
      );
      final image = rgbImage(frame, version: 27);

      final results = await pool.decode(image.rgb, image.px, image.px);

      expect(results, hasLength(1));
      expect(results.single.bytes, equals(frame));
    });

    test(
      'round-robin dispatch correlates every decode to its own frame',
      () async {
        final frames = [for (var i = 0; i < 10; i++) wireFrame(i)];
        final images = [for (final frame in frames) rgbImage(frame)];

        final results = await Future.wait([
          for (var i = 0; i < frames.length; i++)
            pool.decode(images[i].rgb, images[i].px, images[i].px),
        ]);

        for (var i = 0; i < frames.length; i++) {
          expect(results[i], hasLength(1), reason: 'decode $i');
          expect(
            results[i].single.bytes,
            equals(frames[i]),
            reason: 'decode $i',
          );
        }
      },
    );

    test('a blank image yields an empty result list, not an error', () async {
      final blank = Uint8List(256 * 256 * 3);

      final results = await pool.decode(blank, 256, 256);

      expect(results, isEmpty);
    });

    test('malformed dimensions reject instead of hanging the pool', () async {
      final rgb = Uint8List(4 * 4 * 3);

      await expectLater(
        pool.decode(rgb, 4, 5), // 5 * 5 * 3 != rgb.length
        throwsArgumentError,
      );

      final results = await pool.decode(rgb, 4, 4); // pool still healthy
      expect(results, isEmpty);
    });

    test('the same QR image decodes to the same bytes every time', () async {
      final frame = wireFrame(7);
      final image = rgbImage(frame);

      for (var i = 0; i < 5; i++) {
        final results = await pool.decode(image.rgb, image.px, image.px);
        expect(results.single.bytes, equals(frame), reason: 'repeat $i');
      }
    });

    test('decode while workers are still spawning succeeds', () async {
      final frame = wireFrame(1);
      final image = rgbImage(frame);

      // No await on readiness: the pool must queue until the isolates are up.
      final results = await pool.decode(image.rgb, image.px, image.px);

      expect(results.single.bytes, equals(frame));
    });

    test('a default-size pool decodes correctly', () async {
      final defaultPool = DecodePool();
      addTearDown(defaultPool.dispose);
      final frame = wireFrame(2);
      final image = rgbImage(frame);

      final results = await defaultPool.decode(image.rgb, image.px, image.px);

      expect(results.single.bytes, equals(frame));
    });

    test('decode after dispose rejects', () async {
      final disposed = DecodePool(size: 1);
      disposed.dispose();

      await expectLater(disposed.decode(Uint8List(0), 1, 1), throwsStateError);
    });

    test('in-flight decodes reject when the pool is disposed', () async {
      final pending = DecodePool(size: 1);
      final frame = wireFrame(3);
      final image = rgbImage(frame);

      final future = pending.decode(image.rgb, image.px, image.px);
      pending.dispose();

      await expectLater(future, throwsStateError);
    });

    test('dispose is idempotent and safe to call twice', () async {
      final twice = DecodePool(size: 1);
      twice.dispose();
      twice.dispose();

      await expectLater(twice.decode(Uint8List(0), 1, 1), throwsStateError);
    });
  });
}

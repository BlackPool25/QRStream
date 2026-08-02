/// ZXing-C++ decode facade tests — TDD RED/GREEN for
/// `lib/codec/zxing_cpp_bridge.dart` (the native QR decode seam).
///
/// Covers the byte-exact round trip of a real wire frame through the full
/// stack (core encode → QR → rasterize to luma → native zxing-cpp decode) and
/// the dimension-mismatch guard. Requires the Rust dylib; load it once in
/// `setUpAll` (the FFI call is synchronous).
library;

import 'dart:typed_data';

import 'package:qr_transfer_core/codec/raptorq_bridge.dart' show ensureRustLib;
import 'package:qr_transfer_core/codec/zxing_cpp_bridge.dart' show decodeLuma;
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:test/test.dart';

/// Deterministic synthetic DATA wire frame: seed-derived payload so the
/// decoded bytes are checkable against the exact frame bytes.
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

/// Rasterizes [frame] into a tight, row-major luma buffer (dark = 0,
/// light = 255, 1 byte/px) at [ppm] pixels per module with a [quiet]-module
/// white quiet zone — the integer-scale rendering the broadcast sender uses.
({Uint8List luma, int px}) lumaImage(
  Uint8List frame, {
  int ppm = 4,
  int quiet = 4,
  int? version,
}) {
  final qr = encodeQrBytes(frame, version: version);
  final side = qr.size;
  final px = (side + 2 * quiet) * ppm;
  final luma = Uint8List(px * px);
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
      luma[y * px + x] = dark ? 0 : 255;
    }
  }
  return (luma: luma, px: px);
}

void main() {
  group('decodeLuma', () {
    setUpAll(ensureRustLib);

    test('round-trips a core-encoded QR byte-exact', () {
      final frame = wireFrame(0);
      final image = lumaImage(frame);

      final decoded = decodeLuma(image.luma, image.px, image.px);

      expect(decoded, hasLength(1));
      expect(decoded.single, equals(frame));
    });

    test('decodes every QR in one frame', () {
      final frameA = wireFrame(1);
      final frameB = wireFrame(2);
      final a = lumaImage(frameA, version: 17);
      final b = lumaImage(frameB, version: 17);
      // Lay both out side by side on a light canvas with a 16-px gap.
      final gap = 16;
      final h = a.px > b.px ? a.px : b.px;
      final w = a.px + b.px + gap;
      final luma = Uint8List(w * h);
      luma.fillRange(0, luma.length, 255);
      void blit(({Uint8List luma, int px}) img, int x0) {
        final y0 = (h - img.px) ~/ 2;
        for (var y = 0; y < img.px; y++) {
          luma.setRange(
            (y0 + y) * w + x0,
            (y0 + y) * w + x0 + img.px,
            img.luma,
            y * img.px,
          );
        }
      }

      blit(a, 0);
      blit(b, a.px + gap);

      final decoded = decodeLuma(luma, w, h);

      expect(decoded, hasLength(2));
      expect(decoded.toSet(), containsAll([frameA, frameB]));
    });

    test('throws on dimension mismatch', () {
      final frame = wireFrame(3);
      final image = lumaImage(frame);

      // Claim a width*height that does not match the buffer length. The FFI
      // seam throws the Rust `String` error (the facade maps
      // `Result<_, String>` → throw the String), so assert on the message.
      expect(
        () => decodeLuma(image.luma, image.px + 1, image.px),
        throwsA(
          isA<String>().having(
            (e) => e,
            'mentions the mismatch',
            contains('!='),
          ),
        ),
      );
    });
  });
}

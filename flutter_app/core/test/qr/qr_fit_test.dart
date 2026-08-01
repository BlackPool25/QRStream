import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:test/test.dart';

/// Byte-capacity parity with the PWA (src/qr/encode.ts): forced mask 2,
/// Ecc.LOW, exact forced version, and the V33/V34 2k-frame bug regression.
void main() {
  group('profile frames fit at their exact version', () {
    for (final entry in bytesPerTile.entries) {
      final profile = entry.value;
      final frameLen = headerLen + profile.symbolSize + crcLen;
      test('${entry.key.id}: $frameLen bytes at V${profile.version}', () {
        final qr = encodeQrBytes(Uint8List(frameLen), version: profile.version);
        expect((qr.size - 17) ~/ 4, profile.version);
        expect(qr.size, profile.version * 4 + 17);
        expect(qr.modules.length, qr.size * qr.size);
      });
    }
  });

  group('oversize payloads throw QrTooLongException', () {
    test('3000 bytes at V27 exceeds the maximum QR capacity', () {
      expect(
        () => encodeQrBytes(Uint8List(3000), version: 27),
        throwsA(isA<QrTooLongException>()),
      );
    });

    test('2954 bytes at V40 exceeds the version 40 capacity', () {
      expect(
        () => encodeQrBytes(Uint8List(2954), version: 40),
        throwsA(isA<QrTooLongException>()),
      );
    });

    test('1466 bytes at V27 fits a larger version but not 27', () {
      expect(
        () => encodeQrBytes(Uint8List(1466), version: 27),
        throwsA(isA<QrTooLongException>()),
      );
    });

    test('auto-select (no version) throws above the version 40 capacity', () {
      expect(
        () => encodeQrBytes(Uint8List(2954)),
        throwsA(isA<QrTooLongException>()),
      );
    });
  });

  group('mask determinism', () {
    final data = Uint8List.fromList(
      List.generate(64, (i) => (i * 7 + 3) & 0xff),
    );

    test('mask 0 and mask 2 produce different module bitmaps', () {
      final mask0 = encodeQrBytes(data, version: 5, mask: 0);
      final mask2 = encodeQrBytes(data, version: 5, mask: 2);
      expect(mask0.modules, isNot(equals(mask2.modules)));
      expect(mask0.size, mask2.size);
    });

    test('same mask twice produces identical bitmaps', () {
      final first = encodeQrBytes(data, version: 5, mask: 2);
      final second = encodeQrBytes(data, version: 5, mask: 2);
      expect(first.modules, equals(second.modules));
    });
  });

  group('integerScalePx', () {
    test('(177, 800) -> 4', () {
      expect(integerScalePx(177, 800), 4);
    });

    test('(133, 800) -> 6', () {
      expect(integerScalePx(133, 800), 6);
    });

    test('(177, 100) -> 1 (floor with minimum 1)', () {
      expect(integerScalePx(177, 100), 1);
    });
  });

  group('capacity sanity: the PWA V33/V34 bug regression', () {
    test('2082 bytes (2k frame) fits at V34', () {
      final qr = encodeQrBytes(Uint8List(2082), version: 34);
      expect((qr.size - 17) ~/ 4, 34);
    });

    test('2082 bytes (2k frame) does NOT fit at V33', () {
      expect(
        () => encodeQrBytes(Uint8List(2082), version: 33),
        throwsA(isA<QrTooLongException>()),
      );
    });
  });
}

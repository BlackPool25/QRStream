import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/crc32c.dart';
import 'package:test/test.dart';

void main() {
  group('crc32c', () {
    test('matches RFC 3720 check vector crc32c("123456789")', () {
      expect(crc32c(ascii.encode('123456789')), 0xe3069283);
    });

    test('empty input hashes to zero', () {
      expect(crc32c(Uint8List(0)), 0);
    });

    test('matches golden vector for 32 x 0x61', () {
      expect(crc32c(Uint8List.fromList(List.filled(32, 0x61))), 0xb980f10b);
    });

    test('matches PWA crc32c over the random-64k fixture payload '
        '(byte-compatibility proof)', () {
      final data = File(
        'test/fixtures/random-64k/payload.bin',
      ).readAsBytesSync();
      expect(crc32c(data), 0xe1d391a2);
    });
  });

  group('Crc32c streaming', () {
    test('chunked update equals one-shot over 10KB seeded random', () {
      final rng = Random(42);
      final data = Uint8List.fromList(
        List.generate(10 * 1024, (_) => rng.nextInt(256)),
      );
      final split1 = rng.nextInt(256) + 1;
      final split2 = split1 + rng.nextInt(2048) + 1;

      final streamed = Crc32c()
        ..update(data.sublist(0, split1))
        ..update(data.sublist(split1, split2))
        ..update(data.sublist(split2));

      expect(streamed.finalize(), crc32c(data));
    });

    test('finalize on a fresh instance matches empty input', () {
      expect(Crc32c().finalize(), 0);
    });
  });
}

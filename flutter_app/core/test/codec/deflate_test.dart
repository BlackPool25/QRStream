import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:qr_transfer_core/codec/deflate.dart';
import 'package:test/test.dart';

void main() {
  group('compress/decompress round-trip', () {
    test('empty input is reported uncompressed and round-trips empty', () {
      final input = Uint8List(0);

      final result = compress(input);

      expect(result.compressed, isFalse);
      expect(decompress(result), isEmpty);
    });

    test('single byte round-trips byte-identical', () {
      final input = Uint8List.fromList([0x42]);

      final result = compress(input);

      expect(result.compressed, isFalse);
      expect(decompress(result), equals(input));
    });

    test('10KB repeated a compresses (true, smaller) and round-trips', () {
      final input = Uint8List(10 * 1024)..fillRange(0, 10 * 1024, 0x61);

      final result = compress(input);

      expect(result.compressed, isTrue);
      expect(result.data.length, lessThan(input.length));
      expect(decompress(result), equals(input));
    });

    test('10KB seeded random is kept uncompressed and round-trips', () {
      final rng = Random(42);
      final input = Uint8List.fromList(
        List.generate(10 * 1024, (_) => rng.nextInt(256)),
      );

      final result = compress(input);

      expect(result.compressed, isFalse);
      expect(result.data, equals(input));
      expect(decompress(result), equals(input));
    });

    test('100KB mixed text round-trips byte-identical', () {
      final rng = Random(7);
      final input = Uint8List.fromList(
        List.generate(100 * 1024, (_) => 32 + rng.nextInt(95)),
      );

      final result = compress(input);
      expect(decompress(result), equals(input));
    });
  });

  group('determinism', () {
    test('same input compresses to identical bytes on every call', () {
      final input = Uint8List(10 * 1024)..fillRange(0, 10 * 1024, 0x61);

      final first = compress(input).data;
      final second = compress(input).data;

      expect(second, equals(first));
    });
  });

  group('pako byte-parity (cross-engine proof)', () {
    test(
      'Dart zlib level-6 output equals pako deflate fixture byte-for-byte',
      () {
        final original = File(
          'test/fixtures/text-256k/original.bin',
        ).readAsBytesSync();
        final pakoOutput = File(
          'test/fixtures/text-256k/deflate.bin',
        ).readAsBytesSync();

        final result = compress(original);

        expect(result.compressed, isTrue);
        expect(result.data, equals(pakoOutput));
      },
    );

    test('pako deflate fixture inflates back to the original bytes', () {
      final original = File(
        'test/fixtures/text-256k/original.bin',
      ).readAsBytesSync();
      final pakoOutput = File(
        'test/fixtures/text-256k/deflate.bin',
      ).readAsBytesSync();

      final restored = decompress(
        CompressedResult(data: pakoOutput, compressed: true),
      );

      expect(restored, equals(original));
    });
  });

  group('fixtures', () {
    test('random-64k deflate.bin is the uncompressed original '
        '(PWA skip-if-not-smaller)', () {
      final original = File(
        'test/fixtures/random-64k/original.bin',
      ).readAsBytesSync();
      final deflateBin = File(
        'test/fixtures/random-64k/deflate.bin',
      ).readAsBytesSync();

      expect(deflateBin, equals(original));

      final result = compress(original);
      expect(result.compressed, isFalse);
      expect(result.data, equals(original));
    });
  });
}

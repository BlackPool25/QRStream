import 'dart:convert';
import 'dart:io';

import 'package:qr_transfer_core/protocol/sha256.dart';
import 'package:test/test.dart';

// Seeded PRNG (mulberry32, seed 0x12345678) — byte-identical to the Node
// replica used to pin the 1 MiB digest below.
int _state = 0x12345678;

double mulberry32() {
  _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
  final a = _state;
  var t = _imul(a ^ (a >>> 15), 1 | a);
  t = ((t + _imul(t ^ (t >>> 7), 61 | t)) & 0xFFFFFFFF) ^ t;
  t &= 0xFFFFFFFF;
  return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296.0;
}

int _imul(int x, int y) => (x * y) & 0xFFFFFFFF;

void main() {
  group('sha256Hex', () {
    test('SHA-256 of "abc" matches the NIST vector', () {
      expect(
        sha256Hex(ascii.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('SHA-256 of empty input matches the empty-string vector', () {
      expect(
        sha256Hex([]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test(
      'SHA-256 of 1 MiB mulberry32-seeded bytes matches the pinned digest',
      () {
        final bytes = List<int>.generate(
          1024 * 1024,
          (_) => (mulberry32() * 256).floor(),
        );

        expect(
          sha256Hex(bytes),
          '15b3427177ab739e77624fe90966b18af018eec95d5dfdc0b590f128b2efc43a',
        );
      },
    );

    test(
      'SHA-256 of the original.bin fixture matches the manifest fileSHA256',
      () {
        final manifest =
            jsonDecode(
                  File(
                    'test/fixtures/random-64k/manifest.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final bytes = File(
          'test/fixtures/random-64k/original.bin',
        ).readAsBytesSync();

        expect(sha256Hex(bytes), manifest['fileSHA256']);
      },
    );
  });
}

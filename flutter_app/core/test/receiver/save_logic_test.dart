/// save_logic tests (Wave 5 T4.7) — sanitizeFilename + mimeFromFilename,
/// mirroring the PWA's tests/unit/save.test.ts cases for exact parity.
library;

import 'package:qr_transfer_core/receiver/save_logic.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeFilename', () {
    test('turns path separators into underscores', () {
      expect(sanitizeFilename('a/b/c.txt'), 'a_b_c.txt');
      expect(sanitizeFilename('a\\b.txt'), 'a_b.txt');
      expect(sanitizeFilename('..\\evil.txt'), '_evil.txt');
    });

    test('strips leading dots (hidden files / traversal)', () {
      expect(sanitizeFilename('..evil'), 'evil');
      expect(sanitizeFilename('.hidden'), 'hidden');
      expect(sanitizeFilename('....'), 'file');
    });

    test('strips control characters', () {
      expect(sanitizeFilename('a\u0000b\u001fc.txt'), 'abc.txt');
      expect(sanitizeFilename('na\u007fme.txt'), 'name.txt');
    });

    test('truncates over-long names to 180 chars keeping the extension', () {
      final long = 'x' * 300 + '.txt';
      final sanitized = sanitizeFilename(long);
      expect(sanitized.length, 180);
      expect(sanitized.endsWith('.txt'), isTrue);
      expect(sanitized.substring(0, 176), 'x' * 176);
    });

    test('keeps short names intact', () {
      expect(sanitizeFilename('photo.jpg'), 'photo.jpg');
    });
  });

  group('mimeFromFilename', () {
    test('maps known extensions case-insensitively', () {
      expect(mimeFromFilename('x.png'), 'image/png');
      expect(mimeFromFilename('x.mp4'), 'video/mp4');
      expect(mimeFromFilename('x.PDF'), 'application/pdf');
      expect(mimeFromFilename('archive.tar.gz.txt'), 'text/plain');
    });

    test('defaults to application/octet-stream for unknown or missing '
        'extensions', () {
      expect(mimeFromFilename('noext'), 'application/octet-stream');
      expect(mimeFromFilename('thing.zzz'), 'application/octet-stream');
      expect(mimeFromFilename('trailing.'), 'application/octet-stream');
    });
  });
}

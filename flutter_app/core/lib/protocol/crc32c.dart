/// CRC-32C (Castagnoli) over [Uint8List].
///
/// Reflected polynomial 0x1EDC6F41 (reflected form 0x82F63B78), as used by
/// RFC 3720 (iSCSI). Table-driven, verified against the RFC 3720 check value
/// crc32c("123456789") = 0xE3069283. Byte-compatible with the PWA's
/// `src/protocol/crc32c.ts`.
library;

import 'dart:typed_data';

const int _poly = 0x82f63b78;

final List<int> _table = () {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) == 1 ? _poly ^ (c >> 1) : c >> 1;
    }
    table[n] = c & 0xffffffff;
  }
  return table;
}();

/// CRC-32C of a whole buffer, returned as an unsigned 32-bit number.
int crc32c(Uint8List data) {
  final crc = Crc32c();
  crc.update(data);
  return crc.finalize();
}

/// Streaming CRC-32C for chunked frames: call [update] per chunk, then
/// [finalize]. Results are identical to one-shot [crc32c] over the
/// concatenated input.
class Crc32c {
  int _crc = 0xffffffff;

  void update(Uint8List data) {
    var crc = _crc;
    for (final byte in data) {
      // Table index is bounded to [0, 255] by the mask; every value stays
      // within 32 bits, matching JS `>>>` semantics on Dart's 64-bit int.
      crc = _table[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    _crc = crc & 0xffffffff;
  }

  int finalize() => (_crc ^ 0xffffffff) & 0xffffffff;
}

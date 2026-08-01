/// Wire frame encode/decode — port of the PWA's src/protocol/wire.ts, the
/// single source of truth for the transfer frame format. Byte-compatible
/// with the PWA: Frame = Header(30) + Payload(blockLen) + CRC32C(4), all
/// little-endian:
///
///   [0..3]   magic "QRDF" (0x51 0x52 0x44 0x46)
///   [4]      protocol version (1)
///   [5]      frame type: 0x01 DATA, 0x02 META
///   [6..13]  sessionId (8 random bytes per send session)
///   [14..17] esi u32 (RaptorQ encoding symbol id; 0 for META)
///   [18..21] k u32 (total source symbols for this file)
///   [22..25] blockLen u32 (payload length in THIS frame)
///   [26..28] totalLen u24 (total file length post-compression, max 16 MiB)
///   [29]     flags: bit0 = compressed, bits 1-7 reserved (must be 0)
///
/// The CRC32C trailer covers header + payload; decode recomputes it and
/// rejects any mismatch. Decode exposes sessionId as a 16-char lowercase hex
/// string so receivers can dedup by (sessionId, esi).
library;

import 'dart:math';
import 'dart:typed_data';

/// Failure codes for encode/decode validation.
enum ProtocolErrorCode {
  badMagic,
  badVersion,
  badType,
  badEsi,
  badK,
  badTotalLen,
  badFlags,
  badSessionId,
  badCrc,
  truncated,
  badLength,
}

/// Typed protocol error; test and inspect via [code], never message text.
class ProtocolError implements Exception {
  const ProtocolError(this.code, this.message);

  final ProtocolErrorCode code;
  final String message;

  @override
  String toString() => 'ProtocolError(${code.name}): $message';
}

/// A decoded frame. [sessionId] is 16 lowercase hex chars.
class Frame {
  const Frame({
    required this.type,
    required this.sessionId,
    required this.esi,
    required this.k,
    required this.totalLen,
    required this.flags,
    required this.payload,
  });

  final int type;
  final String sessionId;
  final int esi;
  final int k;
  final int totalLen;
  final int flags;
  final Uint8List payload;
}

const int _headerLen = 30;
const int _crcLen = 4;
const int _protoVersion = 1;
const int _typeData = 0x01;
const int _typeMeta = 0x02;
const int _flagCompressed = 0x01;
const int _sessionIdLen = 8;
const int _maxTotalLen = 0xffffff;
const List<int> _magicQrdf = [0x51, 0x52, 0x44, 0x46];

final RegExp _sessionIdRe = RegExp(r'^[0-9a-f]{16}$', caseSensitive: false);

void _assertSessionId(String sessionId) {
  if (!_sessionIdRe.hasMatch(sessionId)) {
    throw ProtocolError(
      ProtocolErrorCode.badSessionId,
      'sessionId must be 16 hex chars, got "$sessionId"',
    );
  }
}

void _assertUint32(int value, ProtocolErrorCode code, String name) {
  if (value < 0 || value > 0xffffffff) {
    throw ProtocolError(code, '$name must be a u32, got $value');
  }
}

void _assertFlags(int flags) {
  if ((flags & ~_flagCompressed) != 0) {
    throw ProtocolError(
      ProtocolErrorCode.badFlags,
      'flags must only use bit0 (compressed), got $flags',
    );
  }
}

/// CRC-32C (Castagnoli), reflected polynomial 0x1EDC6F41 (reflected form
/// 0x82F63B78) as used by RFC 3720 (iSCSI). Table-driven, verified against
/// crc32c("123456789") = 0xE3069283. Port of the PWA's crc32c.ts; T1.1's
/// shared crc32c.dart will supersede this when it lands.
const int _poly = 0x82f63b78;

final List<int> _crcTable = List<int>.generate(256, (int n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? _poly ^ (c >> 1) : c >> 1;
  }
  return c & 0xffffffff;
});

int _crc32c(Uint8List data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

String _hexSessionId(Uint8List bytes, int offset) {
  final buffer = StringBuffer();
  for (var i = 0; i < _sessionIdLen; i++) {
    buffer.write(bytes[offset + i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Encode a frame (header + payload + CRC32C trailer).
Uint8List encodeFrame(Frame frame) {
  if (frame.type != _typeData && frame.type != _typeMeta) {
    throw ProtocolError(
      ProtocolErrorCode.badType,
      'frame type must be 0x01 or 0x02, got ${frame.type}',
    );
  }
  _assertSessionId(frame.sessionId);
  _assertUint32(frame.esi, ProtocolErrorCode.badEsi, 'esi');
  _assertUint32(frame.k, ProtocolErrorCode.badK, 'k');
  _assertFlags(frame.flags);
  if (frame.totalLen < 0 || frame.totalLen > _maxTotalLen) {
    throw ProtocolError(
      ProtocolErrorCode.badTotalLen,
      'totalLen must fit 24 bits, got ${frame.totalLen}',
    );
  }

  final blockLen = frame.payload.length;
  final out = Uint8List(_headerLen + blockLen + _crcLen);
  final view = ByteData.sublistView(out);

  out.setAll(0, _magicQrdf);
  out[4] = _protoVersion;
  out[5] = frame.type;
  for (var i = 0; i < _sessionIdLen; i++) {
    out[6 + i] = int.parse(
      frame.sessionId.substring(i * 2, i * 2 + 2),
      radix: 16,
    );
  }
  view.setUint32(14, frame.esi, Endian.little);
  view.setUint32(18, frame.k, Endian.little);
  view.setUint32(22, blockLen, Endian.little);
  out[26] = frame.totalLen & 0xff;
  out[27] = (frame.totalLen >> 8) & 0xff;
  out[28] = (frame.totalLen >> 16) & 0xff;
  out[29] = frame.flags;
  out.setRange(_headerLen, _headerLen + blockLen, frame.payload);

  final crc = _crc32c(Uint8List.sublistView(out, 0, _headerLen + blockLen));
  view.setUint32(_headerLen + blockLen, crc, Endian.little);
  return out;
}

/// Decode and strictly validate a full frame; throws [ProtocolError] on any
/// violation.
Frame decodeFrame(Uint8List bytes) {
  if (bytes.length < _headerLen + _crcLen) {
    throw ProtocolError(
      ProtocolErrorCode.truncated,
      'frame shorter than header + CRC (${bytes.length} bytes)',
    );
  }
  final view = ByteData.sublistView(bytes);

  for (var i = 0; i < _magicQrdf.length; i++) {
    if (bytes[i] != _magicQrdf[i]) {
      throw ProtocolError(ProtocolErrorCode.badMagic, 'frame magic mismatch');
    }
  }
  if (bytes[4] != _protoVersion) {
    throw ProtocolError(
      ProtocolErrorCode.badVersion,
      'unsupported protocol version ${bytes[4]}',
    );
  }
  final type = bytes[5];
  if (type != _typeData && type != _typeMeta) {
    throw ProtocolError(
      ProtocolErrorCode.badType,
      'unknown frame type 0x${type.toRadixString(16)}',
    );
  }
  final flags = bytes[29];
  if ((flags & ~_flagCompressed) != 0) {
    throw ProtocolError(
      ProtocolErrorCode.badFlags,
      'reserved flag bits set: 0x${flags.toRadixString(16)}',
    );
  }

  final blockLen = view.getUint32(22, Endian.little);
  final expected = _headerLen + blockLen + _crcLen;
  if (bytes.length < expected) {
    throw ProtocolError(
      ProtocolErrorCode.truncated,
      'frame declares blockLen $blockLen but only ${bytes.length} bytes present',
    );
  }
  if (bytes.length != expected) {
    throw ProtocolError(
      ProtocolErrorCode.badLength,
      'frame is ${bytes.length} bytes, expected $expected',
    );
  }

  final computed = _crc32c(
    Uint8List.sublistView(bytes, 0, _headerLen + blockLen),
  );
  if (view.getUint32(_headerLen + blockLen, Endian.little) != computed) {
    throw ProtocolError(ProtocolErrorCode.badCrc, 'CRC32C mismatch');
  }

  return Frame(
    type: type,
    sessionId: _hexSessionId(bytes, 6),
    esi: view.getUint32(14, Endian.little),
    k: view.getUint32(18, Endian.little),
    totalLen: bytes[26] | (bytes[27] << 8) | (bytes[28] << 16),
    flags: flags,
    payload: bytes.sublist(_headerLen, _headerLen + blockLen),
  );
}

/// Generate a fresh 8-byte session id as 16 lowercase hex chars.
String generateSessionId() {
  final random = Random.secure();
  final bytes = Uint8List(_sessionIdLen);
  for (var i = 0; i < _sessionIdLen; i++) {
    bytes[i] = random.nextInt(256);
  }
  return _hexSessionId(bytes, 0);
}

/// Metadata frame build/parse — port of the PWA's src/protocol/metadata.ts.
///
/// A META frame's payload is a UTF-8 JSON document with exact keys:
/// magic, protoVer, sessionId, filename, mime, totalSize, compressedSize,
/// compressed, k, symbolSize, mtu, fileSHA256, flags
/// The sender re-broadcasts the META frame every [metadataRebroadcastEvery]
/// display ticks; receivers parse it via [parseMetadataFrame].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';
import 'wire.dart';

/// Failure codes for metadata build/parse validation.
enum MetadataErrorCode {
  /// Payload is not a JSON object (unparseable or not an object).
  badJson,

  /// A key is missing or has the wrong type.
  badKey,

  /// Payload sessionId differs from the frame header sessionId.
  sessionIdMismatch,

  /// The frame is not a META frame.
  notMeta,

  /// A semantically invalid value (magic, version, hex, range, consistency).
  badValue,
}

/// Typed metadata error; test and inspect via [code], never message text.
class MetadataError implements Exception {
  const MetadataError(this.code, this.message);

  final MetadataErrorCode code;
  final String message;

  @override
  String toString() => 'MetadataError(${code.name}): $message';
}

/// Decoded metadata document. [sessionId] and [fileSHA256] are lowercase hex.
class TransferMetadata {
  const TransferMetadata({
    required this.magic,
    required this.protoVer,
    required this.sessionId,
    required this.filename,
    required this.mime,
    required this.totalSize,
    required this.compressedSize,
    required this.compressed,
    required this.k,
    required this.symbolSize,
    required this.mtu,
    required this.fileSHA256,
    required this.flags,
  });

  final String magic;
  final int protoVer;
  final String sessionId;
  final String filename;
  final String mime;
  final int totalSize;
  final int compressedSize;
  final bool compressed;
  final int k;
  final int symbolSize;
  final int mtu;
  final String fileSHA256;
  final int flags;

  /// Serializes to the 13 payload keys in their canonical wire order.
  Map<String, Object> toJson() => <String, Object>{
    'magic': magic,
    'protoVer': protoVer,
    'sessionId': sessionId,
    'filename': filename,
    'mime': mime,
    'totalSize': totalSize,
    'compressedSize': compressedSize,
    'compressed': compressed,
    'k': k,
    'symbolSize': symbolSize,
    'mtu': mtu,
    'fileSHA256': fileSHA256,
    'flags': flags,
  };

  @override
  bool operator ==(Object other) =>
      other is TransferMetadata &&
      other.magic == magic &&
      other.protoVer == protoVer &&
      other.sessionId == sessionId &&
      other.filename == filename &&
      other.mime == mime &&
      other.totalSize == totalSize &&
      other.compressedSize == compressedSize &&
      other.compressed == compressed &&
      other.k == k &&
      other.symbolSize == symbolSize &&
      other.mtu == mtu &&
      other.fileSHA256 == fileSHA256 &&
      other.flags == flags;

  @override
  int get hashCode => Object.hashAll(<Object>[
    magic,
    protoVer,
    sessionId,
    filename,
    mime,
    totalSize,
    compressedSize,
    compressed,
    k,
    symbolSize,
    mtu,
    fileSHA256,
    flags,
  ]);
}

void _assertHex(String value, int length, String key) {
  final re = RegExp('^[0-9a-f]{$length}\$', caseSensitive: false);
  if (!re.hasMatch(value)) {
    throw MetadataError(
      MetadataErrorCode.badValue,
      'metadata.$key must be $length hex chars',
    );
  }
}

T _reqTyped<T>(Map<String, dynamic> rec, String key, String what) {
  final value = rec[key];
  if (value is! T) {
    throw MetadataError(
      MetadataErrorCode.badKey,
      'metadata.$key must be $what',
    );
  }
  return value;
}

/// Finite number (protoVer keeps its raw value for the exact equality check).
num _reqNumber(Map<String, dynamic> rec, String key) {
  final value = rec[key];
  if (value is! num || !value.isFinite) {
    throw MetadataError(
      MetadataErrorCode.badKey,
      'metadata.$key must be a finite number',
    );
  }
  return value;
}

/// Finite integer; range is validated in [_validate].
int _reqInt(Map<String, dynamic> rec, String key) {
  final value = rec[key];
  if (value is! num || !value.isFinite || value % 1 != 0) {
    throw MetadataError(
      MetadataErrorCode.badKey,
      'metadata.$key must be a finite integer',
    );
  }
  return value.toInt();
}

void _assertUint(int value, int max, String key) {
  if (value < 0 || value > max) {
    throw MetadataError(
      MetadataErrorCode.badValue,
      'metadata.$key must be an integer in [0, $max]',
    );
  }
}

/// Full semantic validation shared by build and parse paths.
void _validate(TransferMetadata meta) {
  if (meta.magic != metaMagic) {
    throw MetadataError(MetadataErrorCode.badValue, 'metadata magic mismatch');
  }
  if (meta.protoVer != protoVersion) {
    throw MetadataError(
      MetadataErrorCode.badValue,
      'unsupported metadata protoVer ${meta.protoVer}',
    );
  }
  _assertHex(meta.sessionId, 16, 'sessionId');
  _assertHex(meta.fileSHA256, 64, 'fileSHA256');
  _assertUint(meta.totalSize, 0xffffffff, 'totalSize');
  _assertUint(meta.compressedSize, maxTotalLen, 'compressedSize');
  _assertUint(meta.k, 0xffffffff, 'k');
  _assertUint(meta.symbolSize, 0xffffffff, 'symbolSize');
  _assertUint(meta.mtu, 0xffffffff, 'mtu');
  _assertUint(meta.flags, flagCompressed, 'flags');
  if (meta.compressed != meta.compressedSize > 0) {
    throw MetadataError(
      MetadataErrorCode.badValue,
      'metadata.compressed must be consistent with compressedSize (0 when uncompressed)',
    );
  }
}

/// Serialize a metadata document to its JSON payload bytes.
Uint8List buildMetadataPayload(TransferMetadata meta) {
  _validate(meta);
  return utf8.encode(jsonEncode(meta.toJson()));
}

/// Parse and strictly validate metadata JSON payload bytes.
TransferMetadata parseMetadataPayload(Uint8List bytes) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw MetadataError(
      MetadataErrorCode.badJson,
      'metadata payload is not a JSON object',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw MetadataError(
      MetadataErrorCode.badJson,
      'metadata payload is not a JSON object',
    );
  }
  final rec = decoded;

  final magic = _reqTyped<String>(rec, 'magic', 'a string');
  if (magic != metaMagic) {
    throw MetadataError(MetadataErrorCode.badValue, 'metadata magic mismatch');
  }
  final protoVerRaw = _reqNumber(rec, 'protoVer');

  final meta = TransferMetadata(
    magic: magic,
    protoVer: protoVerRaw.toInt(),
    sessionId: _reqTyped<String>(rec, 'sessionId', 'a string'),
    filename: _reqTyped<String>(rec, 'filename', 'a string'),
    mime: _reqTyped<String>(rec, 'mime', 'a string'),
    totalSize: _reqInt(rec, 'totalSize'),
    compressedSize: _reqInt(rec, 'compressedSize'),
    compressed: _reqTyped<bool>(rec, 'compressed', 'a boolean'),
    k: _reqInt(rec, 'k'),
    symbolSize: _reqInt(rec, 'symbolSize'),
    mtu: _reqInt(rec, 'mtu'),
    fileSHA256: _reqTyped<String>(rec, 'fileSHA256', 'a string'),
    flags: _reqInt(rec, 'flags'),
  );
  // Exact protoVer equality on the raw value: 1.5 must not pass as 1.
  if (protoVerRaw != protoVersion) {
    throw MetadataError(
      MetadataErrorCode.badValue,
      'unsupported metadata protoVer $protoVerRaw',
    );
  }
  _validate(meta);
  return meta;
}

/// Build a full META wire frame (esi=0, header sessionId = payload sessionId).
Uint8List buildMetadataFrame(TransferMetadata meta) {
  final payload = buildMetadataPayload(meta);
  return encodeFrame(
    Frame(
      type: typeMeta,
      sessionId: meta.sessionId,
      esi: 0,
      k: meta.k,
      totalLen: meta.compressedSize,
      flags: 0,
      payload: payload,
    ),
  );
}

/// Decode a META frame and parse its metadata payload.
TransferMetadata parseMetadataFrame(Uint8List bytes) {
  final frame = decodeFrame(bytes);
  if (frame.type != typeMeta) {
    throw MetadataError(
      MetadataErrorCode.notMeta,
      'expected a META frame, got type 0x${frame.type.toRadixString(16)}',
    );
  }
  final meta = parseMetadataPayload(frame.payload);
  if (meta.sessionId != frame.sessionId) {
    throw MetadataError(
      MetadataErrorCode.sessionIdMismatch,
      'metadata sessionId differs from frame sessionId',
    );
  }
  return meta;
}

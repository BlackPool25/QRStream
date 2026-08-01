import 'dart:io';
import 'dart:typed_data';

/// Result of a best-effort deflate compression.
class CompressedResult {
  CompressedResult({required this.data, required this.compressed});

  /// The compressed bytes when [compressed] is true, otherwise the original.
  final Uint8List data;

  /// Whether [data] is deflated (drives the wire-format flag bit).
  final bool compressed;
}

/// zlib-wrapped deflate at level 6 — byte-compatible with the PWA's
/// pako `deflate(input, { level: 6 })` (both produce zlib-wrapped streams
/// with the same header `78 9c` and the same compressor settings).
final ZLibCodec _zlib = ZLibCodec(raw: false, level: 6);

/// Best-effort deflate compression. Compresses only when it actually shrinks
/// the payload: media like PNG/JPEG/MP4 are already compressed, and deflate
/// would only grow them, so the original bytes are returned untouched and
/// `compressed` stays false.
CompressedResult compress(Uint8List bytes) {
  if (bytes.isEmpty) {
    return CompressedResult(data: bytes, compressed: false);
  }
  final deflated = Uint8List.fromList(_zlib.encode(bytes));
  if (deflated.length >= bytes.length) {
    return CompressedResult(data: bytes, compressed: false);
  }
  return CompressedResult(data: deflated, compressed: true);
}

/// Inflates [result.data] when [result.compressed] is true, otherwise
/// returns the data as-is.
Uint8List decompress(CompressedResult result) {
  if (!result.compressed) {
    return result.data;
  }
  return Uint8List.fromList(_zlib.decode(result.data));
}

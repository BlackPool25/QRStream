/// Receiver-side reassembly: RaptorQ fountain decode → (optional) inflate →
/// SHA-256 integrity gate → the original file bytes, ready for save.
///
/// Pure-Dart port of `src/receiver/reassemble.ts`. The decoder is one-shot per
/// file, so a fresh Reassembler handles one transfer; the camera keeps feeding
/// symbols via [feedMore] until [isComplete]. [ReassemblerLike] is the seam the
/// receiver's live-stats module (T4.2) depends on — defined here so stats.dart
/// can import it from `receiver/reassembler.dart`.
///
/// Integrity layering: CRC32C guards each frame, RaptorQ guards erasure, and
/// the SHA-256 comparison here is the whole-file gate — [finish] only reports
/// verified=true when the decompressed bytes exactly match
/// [TransferMetadata.fileSHA256].
library;

import 'dart:typed_data';

import 'package:qr_transfer_core/codec/deflate.dart';
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/protocol/sha256.dart';

/// Failure codes for the receiver reassembler.
enum ReassemblyErrorCode {
  /// Not enough symbols have arrived to recover the file.
  notComplete,

  /// The reassembled bytes do not match the metadata's SHA-256.
  hashMismatch,

  /// The fountain decoder could not be created or failed while decoding.
  decodeFailed,
}

/// Typed reassembly error; inspect via [code], never message text.
class ReassemblyError implements Exception {
  const ReassemblyError(this.code, this.message);

  final ReassemblyErrorCode code;
  final String message;

  @override
  String toString() => 'ReassemblyError(${code.name}): $message';
}

/// The verified original file, ready for save.
class ReassemblyResult {
  const ReassemblyResult({
    required this.bytes,
    required this.sha256,
    required this.verified,
    required this.mime,
    required this.filename,
  });

  /// The decompressed original file (byte-identical to the sender's file).
  final Uint8List bytes;

  /// SHA-256 of [bytes], matching [TransferMetadata.fileSHA256] when verified.
  final String sha256;

  /// Always true: a mismatching hash throws instead of returning.
  final bool verified;

  final String mime;
  final String filename;
}

/// The reassembly seam the receiver's stats module (T4.2) consumes: feed
/// scanned symbols, learn when the file is complete, finish with the verified
/// bytes, and reset for a new transfer.
abstract class ReassemblerLike {
  /// Records [metadata] and feeds the first batch of [symbols]. One-shot: a
  /// second call throws [ReassemblyError] (decodeFailed) until [reset].
  Future<void> start(
    TransferMetadata metadata,
    List<Uint8List> symbols,
    Set<int> esiSet,
  );

  /// Feeds newly scanned symbols. The caller dedups by esi; duplicates are
  /// harmless, so [esiSet] is advisory only.
  void feedMore(List<Uint8List> symbols, Set<int> esiSet);

  /// True once the fountain decoder has produced the full payload.
  bool get isComplete;

  /// Decompresses, verifies the SHA-256 against the metadata, and returns the
  /// original file. Throws [ReassemblyError] on mismatch or incompleteness.
  Future<ReassemblyResult> finish();

  /// Clears all state so the instance can handle a new transfer.
  void reset();
}

/// One reassembly pass over a transfer, ending at the SHA-256 integrity gate.
///
/// [factory] is injected — the app wires the Rust FFI factory here; core stays
/// FFI-free. The decoder is one-shot per file, so a completed instance must be
/// [reset] before it can reassemble another transfer.
class Reassembler implements ReassemblerLike {
  Reassembler({required int mtu, required FountainFactory factory})
    : _mtu = mtu,
      _factory = factory;

  final int _mtu;
  final FountainFactory _factory;

  TransferMetadata? _metadata;
  FountainDecoder? _decoder;
  Uint8List? _output;
  bool _started = false;
  bool _failed = false;

  @override
  Future<void> start(
    TransferMetadata metadata,
    List<Uint8List> symbols,
    Set<int> esiSet,
  ) async {
    if (_started) {
      throw ReassemblyError(
        ReassemblyErrorCode.decodeFailed,
        'Reassembler.start called twice — call reset()',
      );
    }
    _started = true;
    _metadata = metadata;

    final totalLength = metadata.compressed
        ? metadata.compressedSize
        : metadata.totalSize;
    if (totalLength == 0) {
      // The codec cannot represent a zero-length transfer (its FFI panics on
      // transfer_length 0) and the sender rejects empty files, so a 0-byte
      // file is fully received the moment its metadata arrives.
      _output = Uint8List(0);
      return;
    }

    try {
      _decoder = await _factory.createDecoder(totalLength, _mtu);
    } catch (_) {
      throw ReassemblyError(
        ReassemblyErrorCode.decodeFailed,
        'could not create a decoder for a $totalLength-byte transfer',
      );
    }
    feedMore(symbols, esiSet);
  }

  @override
  void feedMore(List<Uint8List> symbols, Set<int> esiSet) {
    if (_decoder == null || _output != null) {
      return;
    }
    for (final symbol in symbols) {
      Uint8List? result;
      try {
        result = _decoder!.decode(symbol);
      } catch (_) {
        _disposeDecoder();
        _failed = true;
        return;
      }
      if (result != null) {
        _output = result;
        _disposeDecoder();
        return;
      }
    }
  }

  @override
  bool get isComplete => _output != null;

  /// The fountain-decoded bytes (the compressed payload when compressed).
  Uint8List? get decoded => _output;

  @override
  Future<ReassemblyResult> finish() async {
    final metadata = _metadata;
    final output = _output;
    if (_failed) {
      throw ReassemblyError(
        ReassemblyErrorCode.decodeFailed,
        'fountain decode failed',
      );
    }
    if (metadata == null || output == null) {
      throw ReassemblyError(
        ReassemblyErrorCode.notComplete,
        'not enough symbols to reassemble the file',
      );
    }

    final Uint8List payload;
    try {
      payload = metadata.compressed
          ? decompress(CompressedResult(data: output, compressed: true))
          : output;
    } catch (_) {
      throw ReassemblyError(
        ReassemblyErrorCode.decodeFailed,
        'decompressing the decoded payload failed',
      );
    }
    final bytes = Uint8List.fromList(payload);

    final sha256 = sha256Hex(bytes);
    if (sha256 != metadata.fileSHA256) {
      throw ReassemblyError(
        ReassemblyErrorCode.hashMismatch,
        'reassembled bytes do not match the file SHA-256 in the metadata',
      );
    }
    return ReassemblyResult(
      bytes: bytes,
      sha256: sha256,
      verified: true,
      mime: metadata.mime,
      filename: metadata.filename,
    );
  }

  @override
  void reset() {
    _disposeDecoder();
    _metadata = null;
    _output = null;
    _started = false;
    _failed = false;
  }

  void _disposeDecoder() {
    final decoder = _decoder;
    if (decoder != null) {
      decoder.dispose();
      _decoder = null;
    }
  }
}

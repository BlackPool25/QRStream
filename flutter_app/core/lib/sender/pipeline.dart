/// Sender pipeline: file bytes → best-effort deflate → fountain encode →
/// DATA frames + a META frame, ready for the display loop. Pure Dart port of
/// `src/sender/pipeline.ts`.
///
/// Frame ownership: `dataFrames` holds every source-symbol DATA frame;
/// `metaFrames` holds exactly ONE META frame, which the display loop re-emits
/// at cadence. The `encoder` is kept alive on [PreparedTransfer] so the caller
/// can generate repair frames on demand; the caller disposes it when the
/// broadcast stops. No encryption: pure broadcast, no pairing.
///
/// Empty input is rejected with [PipelineErrorCode.emptyFile]: RaptorQ cannot
/// encode a zero-length payload, so an empty transfer has no valid wire
/// representation.
library;

import 'dart:typed_data';

import 'package:qr_transfer_core/codec/deflate.dart';
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/protocol/sha256.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:qr_transfer_core/sender/settings.dart';

/// Failure codes for the sender pipeline.
enum PipelineErrorCode {
  emptyFile,
  tooLarge,
  kSanityFailed,
  frameTooLarge,
  badRepairCount,
}

/// Typed pipeline error; inspect via [code], never message text.
class PipelineError implements Exception {
  const PipelineError(this.code, this.message);

  final PipelineErrorCode code;
  final String message;

  @override
  String toString() => 'PipelineError(${code.name}): $message';
}

/// Read-only snapshot of a prepared transfer, for the UI and the repair path.
class TransferInfo {
  const TransferInfo({
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
    required this.settings,
    required this.bytesPerTile,
  });

  final String sessionId;
  final String filename;
  final String mime;

  /// Original file size in bytes.
  final int totalSize;

  /// Post-compression wire length (== [totalSize] when uncompressed).
  final int compressedSize;

  /// Whether the payload was deflated (drives the wire flag bit).
  final bool compressed;

  /// Total source symbols for this file.
  final int k;

  /// Wire byte size of one encoded symbol.
  final int symbolSize;

  /// Maximum transfer unit (symbol + RaptorQ overhead).
  final int mtu;

  /// Lowercase 64-hex SHA-256 of the original file.
  final String fileSHA256;

  final TransferSettings settings;
  final BytesPerTileId bytesPerTile;

  @override
  bool operator ==(Object other) =>
      other is TransferInfo &&
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
      other.settings == settings &&
      other.bytesPerTile == bytesPerTile;

  @override
  int get hashCode => Object.hashAll(<Object>[
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
    settings,
    bytesPerTile,
  ]);
}

/// A prepared transfer: the source-symbol DATA frames, exactly one META frame
/// and the live encoder for on-demand repair frames.
class PreparedTransfer {
  const PreparedTransfer({
    required this.info,
    required this.dataFrames,
    required this.metaFrames,
    required this.encoder,
  });

  final TransferInfo info;

  /// Every source-symbol DATA wire frame (payload = one fountain symbol).
  final List<Uint8List> dataFrames;

  /// Exactly one META wire frame; the display loop re-emits it at cadence.
  final List<Uint8List> metaFrames;

  /// Kept alive for repair generation; caller disposes when broadcast stops.
  final FountainEncoder encoder;
}

/// Compress the file, fountain-encode it and emit DATA + META wire frames.
///
/// [factory] is injected — the app wires the Rust FFI factory here; core stays
/// FFI-free. Throws [PipelineError] on empty/oversized files and on codec
/// sanity/budget failures; propagates [ArgumentError] from [validateSettings].
Future<PreparedTransfer> prepareTransfer({
  required Uint8List file,
  required String filename,
  required String mime,
  TransferSettings? settings,
  required FountainFactory factory,
}) async {
  if (file.isEmpty) {
    throw PipelineError(
      PipelineErrorCode.emptyFile,
      'cannot transfer an empty file',
    );
  }

  final effectiveSettings = settings ?? defaultTransferSettings;
  validateSettings(effectiveSettings);
  final profile = bytesPerTile[effectiveSettings.bytesPerTile]!;

  final totalSize = file.length;
  final fileSHA256 = sha256Hex(file);

  // Best-effort deflate; [compress] skips when it would not shrink the payload.
  final compressedResult = compress(file);
  final payloadBytes = compressedResult.data;
  final compressed = compressedResult.compressed;
  final compressedSize = payloadBytes.length;
  if (compressedSize > maxTotalLen) {
    throw PipelineError(
      PipelineErrorCode.tooLarge,
      'payload $compressedSize B exceeds the $maxTotalLen B wire totalLen limit',
    );
  }

  // RaptorQ takes the ENTIRE payload as one input: the codec computes
  // K = ceil(len / (mtu - 4)) internally, so there is no manual chunking.
  final encoder = await factory.createEncoder(payloadBytes, profile.mtu);

  final k = encoder.sourceSymbolCount;
  if (k * encoder.symbolSize < compressedSize) {
    throw PipelineError(
      PipelineErrorCode.kSanityFailed,
      'encoder reported k=$k symbols of ${encoder.symbolSize} B < payload $compressedSize B',
    );
  }
  if (encoder.symbolSize > profile.frameBudget) {
    throw PipelineError(
      PipelineErrorCode.frameTooLarge,
      'symbol size ${encoder.symbolSize} B exceeds the profile frameBudget of ${profile.frameBudget} B',
    );
  }

  final sessionId = generateSessionId();
  final flags = compressed ? flagCompressed : 0;

  final dataFrames = encoder
      .encodeSourceSymbols()
      .map(
        (symbol) =>
            _buildDataFrame(sessionId, k, compressedSize, flags, symbol),
      )
      .toList();

  final metaFrame = buildMetadataFrame(
    TransferMetadata(
      magic: metaMagic,
      protoVer: protoVersion,
      sessionId: sessionId,
      filename: filename,
      mime: mime,
      totalSize: totalSize,
      // The protocol pins metadata.compressedSize to 0 when uncompressed
      // (metadata.dart), while the DATA frames carry the true wire length in
      // totalLen and TransferInfo.compressedSize.
      compressedSize: compressed ? compressedSize : 0,
      compressed: compressed,
      k: k,
      symbolSize: encoder.symbolSize,
      mtu: profile.mtu,
      fileSHA256: fileSHA256,
      flags: flags,
    ),
  );

  final info = TransferInfo(
    sessionId: sessionId,
    filename: filename,
    mime: mime,
    totalSize: totalSize,
    compressedSize: compressedSize,
    compressed: compressed,
    k: k,
    symbolSize: encoder.symbolSize,
    mtu: profile.mtu,
    fileSHA256: fileSHA256,
    settings: effectiveSettings,
    bytesPerTile: effectiveSettings.bytesPerTile,
  );

  return PreparedTransfer(
    info: info,
    dataFrames: dataFrames,
    metaFrames: <Uint8List>[metaFrame],
    encoder: encoder,
  );
}

Uint8List _buildDataFrame(
  String sessionId,
  int k,
  int totalLen,
  int flags,
  EncodedSymbol symbol,
) => encodeFrame(
  Frame(
    type: typeData,
    sessionId: sessionId,
    esi: symbol.esi,
    k: k,
    totalLen: totalLen,
    flags: flags,
    payload: symbol.bytes,
  ),
);

/// Build [count] additional DATA frames from the encoder's repair symbols.
List<Uint8List> repairFrames(PreparedTransfer prepared, int count) {
  if (count < 0) {
    throw PipelineError(
      PipelineErrorCode.badRepairCount,
      'repairCount must be a non-negative integer, got $count',
    );
  }
  final info = prepared.info;
  final flags = info.compressed ? flagCompressed : 0;
  // encodeRepair returns the K source symbols followed by `count` repair
  // symbols (see codec/fountain/interface.dart), so slice off the source set.
  return prepared.encoder
      .encodeRepair(count)
      .skip(info.k)
      .map(
        (symbol) => _buildDataFrame(
          info.sessionId,
          info.k,
          info.compressedSize,
          flags,
          symbol,
        ),
      )
      .toList();
}

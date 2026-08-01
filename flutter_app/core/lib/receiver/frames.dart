/// Receiver-side frame buffering: session latching, esi dedup, and bounded
/// repair retention for the wire-frame stream. Pure-Dart port of
/// `src/receiver/frames.ts` — the PWA's "keep scanning" core.
///
/// The sender broadcasts a continuous stream of DATA frames (RaptorQ source
/// and repair symbols) plus a META frame re-broadcast every
/// [metadataRebroadcastEvery] ticks. This buffer latches onto the newest
/// sessionId (a new sender sessionId means a fresh transfer — the buffer
/// resets and starts over), dedups DATA payloads by esi, keeps the latest
/// metadata, and bounds memory by evicting the oldest repair symbols once the
/// distinct-symbol count exceeds k plus the repair budget.
///
/// Session semantics: a DATA or META frame whose sessionId differs from the
/// current one resets the buffer and latches the new session (broadcast
/// restart semantics). A META frame with a new sessionId switches the session
/// exactly like a DATA frame does.
///
/// `feed` never throws for protocol-level corruption: undecodable bytes yield
/// status `error` and increment droppedCount; a META payload that fails to
/// parse yields status `dropped` (also a drop).
///
/// Eviction runs only when k is known (every DATA frame header carries k):
/// once the distinct count exceeds k + budget (budget defaults to
/// floor(k * 0.3) + 1000), the OLDEST repair symbols (esi >= k) are evicted
/// first; source symbols are never evicted. Reassembly (RaptorQ decode)
/// consumes this buffer via [symbols] and [k].
library;

import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/protocol/wire.dart';

/// Outcome of feeding one raw byte slice into the buffer.
enum FeedStatus { ok, dropped, error }

/// Result of [FrameBuffer.feed].
class FeedResult {
  const FeedResult({
    required this.status,
    this.frame,
    this.isNewSession = false,
    this.meta,
  });

  final FeedStatus status;

  /// Present when the bytes decoded to a frame (status ok or dropped).
  final Frame? frame;

  /// True when this feed latched onto a different sessionId.
  final bool isNewSession;

  /// The parsed metadata when this feed was an accepted META frame.
  final TransferMetadata? meta;
}

/// Max number of distinct repair symbols (esi >= k) retained beyond the k
/// source symbols. Default: floor(k * 0.3) + 1000, i.e. a total cap of about
/// 1.3k + 1000 symbols. Fountain decode needs only k source symbols plus a
/// little repair slack; extra repair wastes memory and is evicted oldest
/// first (lowest esi, since repair esi grow over the broadcast).
class FrameBuffer {
  FrameBuffer({int? repairBudget}) : _repairBudget = repairBudget;

  final int? _repairBudget;
  String? _currentSessionId;
  TransferMetadata? _meta;
  int? _latestK;
  final Map<int, Uint8List> _payloadByEsi = <int, Uint8List>{};
  final Set<int> _seenEsi = <int>{};
  int _framesSeen = 0;
  int _dropped = 0;

  /// Feeds one raw wire-frame byte slice. Never throws for protocol-level
  /// corruption: undecodable bytes yield [FeedStatus.error] and increment
  /// droppedCount; a META payload that fails to parse yields
  /// [FeedStatus.dropped] (also a drop). A frame whose sessionId differs
  /// from the current one resets the buffer and latches the new session
  /// (broadcast restart semantics).
  FeedResult feed(Uint8List rawBytes) {
    final Frame frame;
    try {
      frame = decodeFrame(rawBytes);
    } on ProtocolError {
      _dropped++;
      return const FeedResult(status: FeedStatus.error);
    }
    _framesSeen++;

    var isNewSession = false;
    if (frame.sessionId != _currentSessionId) {
      _resetSessionState();
      _currentSessionId = frame.sessionId;
      isNewSession = true;
    }

    if (frame.type == typeData) {
      _latestK = frame.k;
      _storeSymbol(frame);
      return FeedResult(
        status: FeedStatus.ok,
        frame: frame,
        isNewSession: isNewSession,
      );
    }

    try {
      final meta = parseMetadataPayload(frame.payload);
      if (meta.sessionId != frame.sessionId) {
        throw MetadataError(
          MetadataErrorCode.sessionIdMismatch,
          'metadata sessionId differs from frame sessionId',
        );
      }
      _meta = meta;
      _latestK = meta.k;
      return FeedResult(
        status: FeedStatus.ok,
        frame: frame,
        isNewSession: isNewSession,
        meta: meta,
      );
    } on MetadataError {
      _dropped++;
      return FeedResult(
        status: FeedStatus.dropped,
        frame: frame,
        isNewSession: isNewSession,
      );
    }
  }

  /// Number of distinct (sessionId, esi) DATA payloads currently held.
  int get uniqueSymbolCount => _payloadByEsi.length;

  /// Count of successfully decoded frames, including duplicates.
  int get totalFramesSeen => _framesSeen;

  /// Count of frames dropped as corrupt or invalid (see [feed]).
  int get droppedCount => _dropped;

  /// Metadata of the current session (null until a META frame arrives).
  TransferMetadata? get metadata => _meta;

  /// SessionId of the current session.
  String? get sessionId => _currentSessionId;

  /// k of the current session, from META or the latest DATA header.
  int? get k => _latestK;

  /// Distinct DATA payloads sorted by esi (source symbols first, then repair).
  List<Uint8List> symbols() {
    final entries = _payloadByEsi.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [for (final entry in entries) entry.value];
  }

  /// Esis of the distinct DATA payloads currently held.
  Set<int> symbolEsiSet() => Set<int>.of(_payloadByEsi.keys);

  /// Clears all session state (symbols, metadata, k, sessionId). The
  /// cumulative counters totalFramesSeen/droppedCount are scan-health stats
  /// and survive.
  void reset() => _resetSessionState();

  void _storeSymbol(Frame frame) {
    final esi = frame.esi;
    if (!_seenEsi.contains(esi)) {
      _seenEsi.add(esi);
      _payloadByEsi[esi] = frame.payload;
    }
    final budget = _repairBudget ?? (frame.k * 0.3).floor() + 1000;
    final maxSymbols = frame.k + budget;
    if (_payloadByEsi.length > maxSymbols) {
      _evictOldestRepair(maxSymbols, frame.k);
    }
  }

  void _evictOldestRepair(int maxSymbols, int k) {
    final repairEsi = _payloadByEsi.keys.where((esi) => esi >= k).toList()
      ..sort();
    for (final esi in repairEsi) {
      if (_payloadByEsi.length <= maxSymbols) {
        break;
      }
      _payloadByEsi.remove(esi);
      _seenEsi.remove(esi);
    }
  }

  void _resetSessionState() {
    _currentSessionId = null;
    _meta = null;
    _latestK = null;
    _seenEsi.clear();
    _payloadByEsi.clear();
  }
}

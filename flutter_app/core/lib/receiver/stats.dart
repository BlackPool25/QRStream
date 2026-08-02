/// Receiver stats/derived-state + feed bookkeeping — pure-Dart port of
/// `src/receiver/stats.ts`, exact-number parity with the PWA.
///
/// The numbers the status overlay shows (progress, ETA, decode rate,
/// downsample target, feed/reassembler bookkeeping) live here; the
/// [FrameBuffer], [FeedResult] and [ReassemblerLike] surfaces below are the
/// minimal contracts this module consumes — reconcile with the frames and
/// reassembler ports (T4.1/T4.3) when they land.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/metadata.dart';

/// Draw target for a camera capture: at most 2 MP.
const maxPixels = 2000000;

/// Shorthand for the idle status so the empty record literal stays on one line.
const _idleStatus = ReceiverStatus.idle;

/// Draw target for a camera capture: never wider than 1280 px.
const maxDownsampleWidth = 1280;

/// Lifecycle state of the receiver shown in the overlay.
enum ReceiverStatus { idle, scanning, transferring, complete, error }

/// Immutable snapshot of receiver progress and scan health.
///
/// A class over a positional record (field order: status, unique, k,
/// totalFramesSeen, droppedCount, decodeRate, bytesPerSecond, etaSeconds,
/// progress, metaSeen, fileName, verified): record literals give structural
/// ==/hashCode with no per-field boilerplate, and the getters below expose the
/// fields.
class ReceiverStats {
  const ReceiverStats(this._v);

  /// A zeroed snapshot suitable as the first `prev` for [updateStats].
  const ReceiverStats.empty()
    : _v = (_idleStatus, 0, null, 0, 0, 0, 0, null, 0, false, null, null);

  final (
    ReceiverStatus,
    int,
    int?,
    int,
    int,
    double,
    double,
    double?,
    double,
    bool,
    String?,
    bool?,
  )
  _v;

  ReceiverStatus get status => _v.$1;
  int get unique => _v.$2;
  int? get k => _v.$3;
  int get totalFramesSeen => _v.$4;
  int get droppedCount => _v.$5;

  /// Decoded video frames per second (EMA).
  double get decodeRate => _v.$6;
  double get bytesPerSecond => _v.$7;

  /// Seconds to receive the remaining symbols; null while unknowable.
  double? get etaSeconds => _v.$8;

  /// 0..1: unique/k when k is known, else 0.
  double get progress => _v.$9;

  /// Whether transfer metadata (and thus symbol size) is known.
  bool get metaSeen => _v.$10;
  String? get fileName => _v.$11;
  bool? get verified => _v.$12;

  @override
  bool operator ==(Object other) => other is ReceiverStats && _v == other._v;

  @override
  int get hashCode => _v.hashCode;
}

/// Per-window inputs for one [updateStats] call.
class StatsSample {
  const StatsSample(this._v);

  final (int, int?, int, int, int, int?, int, int) _v;

  int get unique => _v.$1;
  int? get k => _v.$2;
  int get totalFramesSeen => _v.$3;
  int get droppedCount => _v.$4;
  int get elapsedMs => _v.$5;

  /// Transfer symbol size; null until metadata is known.
  int? get symbolSize => _v.$6;

  /// Decoded frames counted inside this stats window.
  int get decodedInWindow => _v.$7;
  int get windowMs => _v.$8;
}

/// Outcome of feeding one raw byte slice into the frame buffer.
enum FeedStatus { ok, dropped, error }

/// The slice of a frame-buffer feed result the feed handler consumes.
class FeedResult {
  const FeedResult({required this.status, this.isNewSession = false});

  final FeedStatus status;

  /// True when this feed latched onto a different sessionId.
  final bool isNewSession;
}

/// The frame-buffer surface [handleFeedResult] drives (real instance or a
/// test fake). The real buffer (T4.1) exposes exactly this shape.
abstract interface class FrameBuffer {
  /// Metadata of the current session; null until a META frame arrives.
  TransferMetadata? get metadata;

  /// Distinct DATA payloads sorted by esi (source symbols first, then repair).
  List<Uint8List> symbols();

  /// Esis of the distinct DATA payloads currently held.
  Set<int> symbolEsiSet();
}

/// What [handleFeedResult] did to the reassembler.
enum FeedAction { reset, start, feedMore, none }

/// Feed bookkeeping: whether start() ran and which esi already reached the
/// decoder.
class FeedState {
  const FeedState({required this.started, required this.fedEsi});

  final bool started;
  final Set<int> fedEsi;
}

/// Result of applying one feed result to the reassembler.
typedef FeedHandling = ({FeedAction action, FeedState state});

/// The reassembler surface [handleFeedResult] drives (real instance or a test
/// fake). The real reassembler (T4.3) implements this contract.
abstract interface class ReassemblerLike {
  Future<void> start(
    TransferMetadata metadata,
    List<Uint8List> symbols,
    Set<int> esiSet,
  );

  void feedMore(List<Uint8List> symbols, Set<int> esiSet);

  bool get isComplete;

  Future<void> finish();

  void reset();
}

/// Draw target for a camera capture: at most [maxPixels] and never wider than
/// [maxDownsampleWidth]. Degenerate inputs fall back to 1x1.
({int width, int height}) downsampleTarget(
  int captureWidth,
  int captureHeight,
) {
  if (captureWidth <= 0 || captureHeight <= 0) {
    return (width: 1, height: 1);
  }
  final scale = math.min(
    1.0,
    math.min(
      math.sqrt(maxPixels / (captureWidth * captureHeight)),
      maxDownsampleWidth / captureWidth,
    ),
  );
  var width = math.max(1, (captureWidth * scale).round());
  var height = math.max(1, (captureHeight * scale).round());
  while (width * height > maxPixels) {
    if (width > height) {
      width -= 1;
    } else {
      height -= 1;
    }
  }
  return (width: width, height: height);
}

/// Seconds to receive the remaining symbols; null while unknowable.
double? estimateEta(
  int unique,
  int? k,
  double bytesPerSecond,
  int? symbolSize,
) {
  if (k == null ||
      k <= 0 ||
      bytesPerSecond <= 0 ||
      symbolSize == null ||
      symbolSize <= 0) {
    return null;
  }
  if (unique >= k) {
    // The frame buffer counts repair symbols (esi >= k) too, so unique
    // meeting/exceeding k does not mean the transfer is done — the decoder is
    // still working. ETA 0 would read as complete, so it must be unknowable.
    return null;
  }
  return (k - unique) * symbolSize / bytesPerSecond;
}

/// 0..1: unique/k when k is known, else 0.
double progressOf(int unique, int? k) {
  if (k == null || k <= 0) return 0;
  return math.min(1.0, math.max(0.0, unique / k));
}

/// EMA blend with a 1s time constant, clamped to the window length.
double _emaBlend(double prev, double instant, int windowMs) {
  if (windowMs <= 0) return prev;
  final alpha = math.min(1.0, windowMs / 1000);
  return prev * (1 - alpha) + instant * alpha;
}

/// Windowed receive rate: how many NEW symbols arrived in this window, times
/// the symbol size, per second — EMA-blended with the previous rate. Unlike a
/// lifetime average (unique × size / total elapsed), this reflects the current
/// decode throughput, so the ETA it feeds stays honest.
double _windowedBytesPerSecond(ReceiverStats prev, StatsSample sample) {
  final size = sample.symbolSize;
  if (size == null || size <= 0 || sample.windowMs <= 0) return 0.0;
  final delta = math.max(0, sample.unique - prev.unique);
  final instant = delta * size / (sample.windowMs / 1000);
  return _emaBlend(prev.bytesPerSecond, instant, sample.windowMs);
}

/// Stateful projection: decodeRate is an EMA of every window seen so far.
ReceiverStats updateStats(ReceiverStats prev, StatsSample sample) {
  final instant = sample.windowMs <= 0
      ? 0.0
      : (sample.decodedInWindow / sample.windowMs) * 1000;
  final decodeRate = _emaBlend(prev.decodeRate, instant, sample.windowMs);
  final size = sample.symbolSize;
  final bytesPerSecond = _windowedBytesPerSecond(prev, sample);
  return ReceiverStats((
    prev.status,
    sample.unique,
    sample.k,
    sample.totalFramesSeen,
    sample.droppedCount,
    decodeRate,
    bytesPerSecond,
    estimateEta(sample.unique, sample.k, bytesPerSecond, size),
    progressOf(sample.unique, sample.k),
    size != null,
    prev.fileName,
    prev.verified,
  ));
}

/// Applies one frame-buffer feed result to the reassembler. A new session
/// resets the reassembler; once metadata is known, every held symbol whose esi
/// has not been handed over yet is start()ed (first batch) or feedMore()d (the
/// rest). The buffer sorts symbols() by esi, so pairing the sorted esi list
/// with symbols() at the same index keeps esi->payload alignment.
Future<FeedHandling> handleFeedResult({
  required FrameBuffer buffer,
  required ReassemblerLike reassembler,
  required FeedResult result,
  required FeedState state,
}) async {
  var next = state;
  if (result.isNewSession) {
    reassembler.reset();
    next = FeedState(started: false, fedEsi: <int>{});
  }
  final metadata = buffer.metadata;
  if (result.status != FeedStatus.ok || metadata == null) {
    return (
      action: result.isNewSession ? FeedAction.reset : FeedAction.none,
      state: next,
    );
  }
  final symbols = buffer.symbols();
  final esiList = buffer.symbolEsiSet().toList()..sort();
  final toFeed = <Uint8List>[];
  final newlyFed = <int>[];
  for (var i = 0; i < esiList.length; i++) {
    final esi = esiList[i];
    if (next.fedEsi.contains(esi)) continue;
    toFeed.add(symbols[i]);
    newlyFed.add(esi);
  }
  if (toFeed.isEmpty) return (action: FeedAction.none, state: next);
  final fedEsi = Set<int>.of(next.fedEsi)..addAll(newlyFed);
  final fedState = FeedState(started: true, fedEsi: fedEsi);
  if (next.started) {
    reassembler.feedMore(toFeed, buffer.symbolEsiSet());
    return (action: FeedAction.feedMore, state: fedState);
  }
  await reassembler.start(metadata, toFeed, buffer.symbolEsiSet());
  return (action: FeedAction.start, state: fedState);
}

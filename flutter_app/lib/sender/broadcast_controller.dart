/// Broadcast display controller — the Flutter port of the PWA's
/// `SenderDisplay` loop (src/sender/display.ts), driven by a [Ticker] instead
/// of requestAnimationFrame.
///
/// The loop renders a continuously-cycling grid of QR codes, one frame per
/// display tick, at the frame-delay cadence for the current fps. Every
/// [metadataRebroadcastEvery] ticks one data tile becomes the META frame
/// (slot 0) so receivers joining mid-broadcast learn the session + file; the
/// remaining tiles carry a deterministic round-robin schedule of RaptorQ
/// source/repair frames (receivers dedup by esi).
///
/// QR encoding runs in a BACKGROUND isolate ([QrEncodeWorker]) with a bounded
/// per-esi matrix cache: the controller requests frames a few ticks ahead
/// (lookahead) and the worker encodes + caches them, so the UI isolate only
/// drains ready matrices and repaints — never encodes. When the worker cannot
/// keep up, the tick is skipped (the previous frame stays on screen) and the
/// effective fps drops naturally. Tests inject a synchronous [EncodeBackend].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/sender/encode_worker.dart';
import 'package:qr_transfer_core/sender/pacing.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// How many frames ahead of the rendered frame the loop keeps the encode
/// worker busy (encode lookahead + in-flight slack).
const int _lookaheadFrames = 4;

/// Maximum buffered-but-not-yet-displayed frames; older entries are dropped.
const int _readyFrameCap = 32;

/// One completed frame from the encode backend: its tiles plus the round-robin
/// esi schedule they carry (so the view can key cached tile bitmaps by esi).
typedef DrainedFrame = ({
  int frameIndex,
  List<QrMatrix?> tiles,
  List<int> esis,
});

/// Broadcast display controller for one prepared transfer.
class BroadcastController {
  /// [settings] must carry the same bytesPerTile as
  /// [PreparedTransfer.info] — the frames are sized for that symbol.
  /// [canvasWidth]/[canvasHeight] seed the layout suggestion; they default to
  /// 0 so the pre-start pacing is unaffected (matching the PWA, where the
  /// canvas is sized at start()).
  ///
  /// [onFramesDrained] fires with every batch of frames the encode backend
  /// completes — including frames buffered ahead of the one displayed — so
  /// the view can pre-decode tile bitmaps before they appear on screen.
  BroadcastController({
    required PreparedTransfer prepared,
    required TransferSettings settings,
    required TickerProvider vsync,
    ValueChanged<SenderStats>? onStats,
    ValueChanged<List<DrainedFrame>>? onFramesDrained,
    EncodeBackend? encode,
    int canvasWidth = 0,
    int canvasHeight = 0,
  }) : _prepared = prepared,
       _settings = settings,
       // The public parameter cannot be an initializing formal for the
       // private `_onStats` / `_onFramesDrained` fields.
       // ignore: prefer_initializing_formals
       _onStats = onStats,
       // ignore: prefer_initializing_formals
       _onFramesDrained = onFramesDrained,
       _pool = FramePool(
         k: prepared.info.k,
         dataFrames: () => prepared.dataFrames,
         // core's repairFrames slices off `k` symbols assuming encodeRepair
         // emits a K-source prefix, but the real FFI facade returns exactly
         // `count` repair packets — request count + k so the slice yields
         // `count` frames. If core is ever fixed, an over-long cache is
         // harmless (the pool never indexes past repairAvailable).
         repairFrames: (count) =>
             repairFrames(prepared, count + prepared.info.k),
       ),
       currentFps = resolvePacing(
         settings,
         canvasWidth,
         canvasHeight,
       ).effectiveFps {
    _version = bytesPerTile[settings.bytesPerTile]!.version;
    _grid = layouts[settings.layout]!;
    _tilesPerFrame = _grid.cols * _grid.rows;
    // Encoding lives in a background isolate by default; tests inject a
    // synchronous backend.
    _encode = encode ?? QrEncodeWorker(version: _version);
    _ticker = vsync.createTicker(_onTick);
  }

  final PreparedTransfer _prepared;
  final TransferSettings _settings;
  final ValueChanged<SenderStats>? _onStats;
  final ValueChanged<List<DrainedFrame>>? _onFramesDrained;
  final FramePool _pool;

  late final EncodeBackend _encode;
  late final Ticker _ticker;
  late final int _version;
  late final ({int cols, int rows}) _grid;
  late final int _tilesPerFrame;

  /// Current broadcast cadence (fps): starts at the resolved effective fps
  /// and only steps down when a tick overruns its frame budget.
  int currentFps;

  final _FrameSignal _frameSignal = _FrameSignal();

  /// Notified after every rendered frame so the view's CustomPaint repaints.
  Listenable get frameSignal => _frameSignal;

  int _renderedTicks = 0;
  int _failedTicks = 0;
  double _lastRenderTimeMs = 0;
  double _lastStatsTimeMs = 0;
  int _lastStatsTickCount = 0;
  bool _started = false;
  bool _boost = false;
  bool _disposed = false;

  // Encode-pipeline state.
  int _nextRequest = 0; // next frame index to ask the worker for
  final Map<int, DrainedFrame> _ready = {}; // frames buffered ahead

  final Stopwatch _workStopwatch = Stopwatch();

  List<QrMatrix?> _currentTiles = const <QrMatrix?>[];
  List<int> _lastEsis = const <int>[];
  bool _lastFrameMeta = false;

  /// Frames actually rendered since [start].
  int get tickCount => _renderedTicks;

  /// Tiles skipped because QR encoding failed.
  int get droppedTicks => _failedTicks;

  /// The most recently rendered tile list (empty before the first render).
  /// On meta ticks (see [lastFrameMeta]) slot 0 is the META QR.
  List<QrMatrix?> get currentFrame => _currentTiles;

  /// Whether the last rendered frame carried the META frame in slot 0.
  bool get lastFrameMeta => _lastFrameMeta;

  /// The round-robin esi schedule of the last rendered frame.
  List<int> get lastEsis => _lastEsis;

  /// The transfer settings this controller broadcasts with.
  TransferSettings get settings => _settings;

  /// QR version used for every tile (from the settings' bytes-per-tile).
  int get version => _version;

  /// Tiles per frame for the settings' layout (cols × rows).
  int get tilesPerFrame => _tilesPerFrame;

  /// Begins the broadcast. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _lastRenderTimeMs = 0;
    _lastStatsTimeMs = 0;
    _lastStatsTickCount = 0;
    if (_boost) unawaited(_applyWakelock(true));
    _ticker.start();
  }

  /// Pauses the broadcast. The encoder stays alive (see [dispose]).
  void stop() {
    if (!_started) return;
    _started = false;
    _ticker.stop();
    if (_boost) unawaited(_applyWakelock(false));
  }

  /// Stops the loop, releases the wake lock if held, disposes the encode
  /// worker and frees the RaptorQ encoder. Idempotent; call once when the
  /// broadcast is done.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _ticker.dispose();
    _frameSignal.dispose();
    _encode.dispose();
    _prepared.encoder.dispose();
  }

  /// Screen-awake boost: holds the wake lock while boosting. Brightness has
  /// no standard API — the UI tells the user to raise it.
  void setBoost(bool active) {
    if (_boost == active) return;
    _boost = active;
    if (_started) unawaited(_applyWakelock(active));
  }

  /// The Ticker tick. Ticks that arrive before the frame delay are skipped
  /// (holding fps at or below the target so QRs phase-drift across camera
  /// captures); otherwise the loop keeps the encode worker ~[_lookaheadFrames]
  /// ahead, drains any completed frames and applies at most ONE (so the
  /// display cadence stays disciplined — a worker that lags simply causes
  /// skipped ticks, never a UI-thread encode).
  void _onTick(Duration elapsed) {
    final nowMs = elapsed.inMicroseconds / 1000;
    final frameDelayMs = computeFrameDelayMs(currentFps);
    if (nowMs - _lastRenderTimeMs < frameDelayMs) {
      return;
    }
    _lastRenderTimeMs = nowMs;

    _workStopwatch
      ..reset()
      ..start();
    // Keep the worker ahead of the rendered frame.
    while (_nextRequest < _renderedTicks + _lookaheadFrames) {
      _requestFrame(_nextRequest);
      _nextRequest++;
    }
    _drainAndApply();
    final workMs = _workStopwatch.elapsedMicroseconds / 1000;
    currentFps = adaptFps(currentFps, workMs.round(), frameDelayMs);
    _emitStatsIfDue(nowMs);
  }

  /// Requests the tiles for one frame from the encode backend: the META QR in
  /// slot 0 on meta ticks, then data tiles from the deterministic round-robin
  /// esi schedule. Public so tests can drive frames directly.
  void renderFrame(int frameIndex) {
    _requestFrame(frameIndex);
    _drainAndApply();
  }

  void _requestFrame(int frameIndex) {
    final showMeta = frameIndex % metadataRebroadcastEvery == 0;
    final reqEsis = <int>[];
    final reqBytes = <Uint8List?>[];
    if (isDualLaneLayout(_settings.layout)) {
      final laneEsis = nextEsiDualLane(
        _pool.k,
        _pool.repairAvailable,
        frameIndex,
      );
      if (showMeta) {
        // Position-stable META in lane 0; slot 1 carries its scheduled data
        // esi (same dataTiles = tilesPerFrame - 1 semantics as the grid
        // layouts, but for dual-lane the META replaces lane 0's tile).
        reqEsis.add(metaSlotEsi);
        reqBytes.add(_prepared.metaFrames.first);
        reqEsis.add(laneEsis[1]);
        reqBytes.add(_pool.frameBytes(laneEsis[1]));
      } else {
        for (final esi in laneEsis) {
          reqEsis.add(esi);
          reqBytes.add(_pool.frameBytes(esi));
        }
      }
    } else {
      final dataTiles = showMeta ? _tilesPerFrame - 1 : _tilesPerFrame;
      final esis = nextEsiRoundRobin(
        _pool.k,
        _pool.repairAvailable,
        frameIndex,
        dataTiles,
      );
      if (showMeta) {
        reqEsis.add(metaSlotEsi);
        reqBytes.add(_prepared.metaFrames.first);
      }
      for (final esi in esis) {
        reqEsis.add(esi);
        reqBytes.add(_pool.frameBytes(esi));
      }
    }
    _encode.requestFrame(
      frameIndex: frameIndex,
      esis: reqEsis,
      frameBytes: reqBytes,
    );
  }

  /// Drains completed frames from the backend: late frames (already rendered)
  /// are dropped, the next-in-order frame is applied (at most one per call,
  /// keeping the display cadence), and the rest stay buffered (bounded).
  void _drainAndApply() {
    for (final (frameIndex, tiles) in _encode.drain()) {
      if (frameIndex < _renderedTicks) continue; // late — drop
      _ready[frameIndex] = _frameWithEsis(frameIndex, tiles);
    }
    final onFrames = _onFramesDrained;
    if (onFrames != null && _ready.isNotEmpty) {
      onFrames(_ready.values.toList());
    }
    final next = _ready.remove(_renderedTicks);
    if (next != null) {
      _applyFrame(next);
      _renderedTicks++;
    }
    if (_ready.length > _readyFrameCap) {
      final keys = _ready.keys.toList()..sort();
      while (_ready.length > _readyFrameCap) {
        _ready.remove(keys.removeAt(0));
      }
    }
  }

  /// Recomputes the esi schedule for [frameIndex] and pairs it with the tile
  /// list the backend produced. For dual-lane layouts this is the same pure
  /// [nextEsiDualLane] call [_requestFrame] used — the META slot-0 override
  /// lives only in the requested tile bytes, exactly like the grid layouts'
  /// `_frameWithEsis` returns the data-only round-robin schedule on meta ticks.
  DrainedFrame _frameWithEsis(int frameIndex, List<QrMatrix?> tiles) {
    final showMeta = frameIndex % metadataRebroadcastEvery == 0;
    if (isDualLaneLayout(_settings.layout)) {
      return (
        frameIndex: frameIndex,
        tiles: tiles,
        esis: nextEsiDualLane(_pool.k, _pool.repairAvailable, frameIndex),
      );
    }
    return (
      frameIndex: frameIndex,
      tiles: tiles,
      esis: nextEsiRoundRobin(
        _pool.k,
        _pool.repairAvailable,
        frameIndex,
        showMeta ? _tilesPerFrame - 1 : _tilesPerFrame,
      ),
    );
  }

  void _applyFrame(DrainedFrame frame) {
    final showMeta = frame.frameIndex % metadataRebroadcastEvery == 0;
    _currentTiles = frame.tiles;
    _lastEsis = frame.esis;
    _lastFrameMeta = showMeta;
    for (final tile in frame.tiles) {
      if (tile == null) _failedTicks++;
    }
    _frameSignal.emit();
  }

  void _emitStatsIfDue(double nowMs) {
    final onStats = _onStats;
    if (onStats == null || nowMs - _lastStatsTimeMs < 500) return;
    final dtMs = nowMs - _lastStatsTimeMs;
    final dtTicks = _renderedTicks - _lastStatsTickCount;
    onStats(
      SenderStats(
        tickCount: _renderedTicks,
        fps: dtMs > 0 ? (dtTicks / dtMs * 1000).round() : 0,
        droppedTicks: _failedTicks,
        avgTickMs: _renderedTicks > 0
            ? (nowMs / _renderedTicks * 10).round() / 10
            : 0,
        layout: _settings.layout,
        k: _pool.k,
      ),
    );
    _lastStatsTimeMs = nowMs;
    _lastStatsTickCount = _renderedTicks;
  }

  /// Screen-awake is best-effort: a missing platform channel (e.g. in tests)
  /// or a plugin failure must not kill the broadcast.
  Future<void> _applyWakelock(bool enable) async {
    try {
      if (enable) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } on Exception {
      // Best-effort; see doc comment.
    }
  }
}

/// Internal notifier behind [BroadcastController.frameSignal]. Subclassing
/// ChangeNotifier lets the controller emit frame signals without exposing the
/// protected notifyListeners outside the class.
class _FrameSignal extends ChangeNotifier {
  void emit() {
    notifyListeners();
  }
}

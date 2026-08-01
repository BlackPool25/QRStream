/// Broadcast display controller — the Flutter port of the PWA's
/// `SenderDisplay` loop (src/sender/display.ts), driven by a [Ticker] instead
/// of requestAnimationFrame.
///
/// The loop renders a continuously-cycling grid of QR codes, one frame per
/// display tick, at the frame-delay cadence for the current fps. Every
/// [metadataRebroadcastEvery] ticks one data tile becomes the META frame
/// (slot 0) so receivers joining mid-broadcast learn the session + file; the
/// remaining tiles carry a deterministic round-robin schedule of RaptorQ
/// source/repair frames (receivers dedup by esi). The loop measures each
/// tick's encode work and steps the fps down (floor [minFps]) when a frame
/// overruns its budget, and it emits [SenderStats] roughly every 500ms.
///
/// Logic-only: the controller builds [QrMatrix] tiles — the view paints them
/// (see `lib/ui/qr_grid_painter.dart`), repainting on [frameSignal]. This
/// keeps the loop unit-testable without widgets.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/sender/pacing.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Broadcast display controller for one prepared transfer.
class BroadcastController {
  /// [settings] must carry the same bytesPerTile as
  /// [PreparedTransfer.info] — the frames are sized for that symbol.
  /// [canvasWidth]/[canvasHeight] seed the layout suggestion; they default to
  /// 0 so the pre-start pacing is unaffected (matching the PWA, where the
  /// canvas is sized at start()).
  BroadcastController({
    required PreparedTransfer prepared,
    required TransferSettings settings,
    required TickerProvider vsync,
    ValueChanged<SenderStats>? onStats,
    int canvasWidth = 0,
    int canvasHeight = 0,
  })  : _prepared = prepared,
        _settings = settings,
        // The public parameter cannot be an initializing formal for the
        // private `_onStats` field.
        // ignore: prefer_initializing_formals
        _onStats = onStats,
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
        currentFps = resolvePacing(settings, canvasWidth, canvasHeight)
            .effectiveFps {
    _version = bytesPerTile[settings.bytesPerTile]!.version;
    final grid = layouts[settings.layout]!;
    _tilesPerFrame = grid.cols * grid.rows;
    _ticker = vsync.createTicker(_onTick);
  }

  final PreparedTransfer _prepared;
  final TransferSettings _settings;
  final ValueChanged<SenderStats>? _onStats;
  final FramePool _pool;

  late final Ticker _ticker;
  late final int _version;
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

  /// Stops the loop, releases the wake lock if held and frees the RaptorQ
  /// encoder. Idempotent; call once when the broadcast is done.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _ticker.dispose();
    _frameSignal.dispose();
    _prepared.encoder.dispose();
  }

  /// Screen-awake boost: holds the wake lock while boosting. Brightness has
  /// no standard API — the UI tells the user to raise it.
  void setBoost(bool active) {
    if (_boost == active) return;
    _boost = active;
    if (_started) unawaited(_applyWakelock(active));
  }

  /// The Ticker tick — the rAF equivalent. Ticks that arrive before the frame
  /// delay are skipped (holding fps at or below the target so QRs phase-drift
  /// across camera captures); otherwise one frame is rendered, the fps adapts
  /// to the measured encode budget and stats emit when the 500ms window
  /// elapses.
  void _onTick(Duration elapsed) {
    final nowMs = elapsed.inMicroseconds / 1000;
    final frameDelayMs = computeFrameDelayMs(currentFps);
    if (nowMs - _lastRenderTimeMs < frameDelayMs) {
      return;
    }
    _lastRenderTimeMs = nowMs;

    _workStopwatch..reset()..start();
    renderFrame(_renderedTicks);
    _renderedTicks++;
    final workMs = _workStopwatch.elapsedMicroseconds / 1000;
    currentFps = adaptFps(currentFps, workMs.round(), frameDelayMs);
    _emitStatsIfDue(nowMs);
  }

  /// Build the tile list for one frame: the META QR in slot 0 on meta ticks,
  /// then data tiles from the deterministic round-robin esi schedule. Also
  /// public so tests can drive frames directly.
  void renderFrame(int frameIndex) {
    final showMeta = frameIndex % metadataRebroadcastEvery == 0;
    final dataTiles = showMeta ? _tilesPerFrame - 1 : _tilesPerFrame;
    final esis =
        nextEsiRoundRobin(_pool.k, _pool.repairAvailable, frameIndex, dataTiles);

    final tiles = <QrMatrix?>[];
    if (showMeta) {
      tiles.add(_encodeFrame(_prepared.metaFrames.first));
    }
    for (final esi in esis) {
      tiles.add(_encodeFrame(_pool.frameBytes(esi)));
    }

    _currentTiles = tiles;
    _lastEsis = esis;
    _lastFrameMeta = showMeta;
    _frameSignal.emit();
  }

  QrMatrix? _encodeFrame(Uint8List frameBytes) {
    try {
      return encodeQrBytes(frameBytes, version: _version);
    } on Exception {
      // A frame that does not fit its QR version is an integration bug; the
      // PWA converts it into a skipped tile + dropped-tick count, never a
      // crash.
      _failedTicks++;
      return null;
    }
  }

  void _emitStatsIfDue(double nowMs) {
    final onStats = _onStats;
    if (onStats == null || nowMs - _lastStatsTimeMs < 500) return;
    final dtMs = nowMs - _lastStatsTimeMs;
    final dtTicks = _renderedTicks - _lastStatsTickCount;
    onStats(SenderStats(
      tickCount: _renderedTicks,
      fps: dtMs > 0 ? (dtTicks / dtMs * 1000).round() : 0,
      droppedTicks: _failedTicks,
      avgTickMs:
          _renderedTicks > 0 ? (nowMs / _renderedTicks * 10).round() / 10 : 0,
      layout: _settings.layout,
      k: _pool.k,
    ));
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

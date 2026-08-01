/// Sender broadcast pacing + packet scheduling — pure-Dart port of
/// `src/sender/pacing.ts`, exact-number parity with the PWA.
///
/// The display loop consumes these to keep the broadcast's frame rate
/// disciplined: display fps must stay below the camera's capture fps, and
/// each frame must get >= 2 display refresh cycles.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';

/// Fps ceiling per layout: the 3x3 grid is render-heavy (9 tiles/frame) so
/// it caps at 24; the others may run up to 30 when the device allows.
const layoutMaxFps = <LayoutId, int>{
  LayoutId.single: 30,
  LayoutId.column3: 30,
  LayoutId.row3: 30,
  LayoutId.grid4: 30,
  LayoutId.grid9: 24,
};

/// Min square-canvas side (px) at which the 2x2 grid is worthwhile.
const grid4MinCanvasPx = 800;

/// Min square-canvas side (px) at which the 3x3 grid is worthwhile.
const grid9MinCanvasPx = 1800;

/// Hard floor the display loop throttles down to before giving up on fps.
const minFps = 8;

/// Default encode+render margin over the frame delay used by [renderBudgetOk].
const defaultOverheadFactor = 1.5;

/// Extra repair symbols generated lazily beyond k: ceil(k * 0.3) + 100.
const repairExtraFactor = 0.3;
const repairExtraMin = 100;

/// How far a single over-budget tick steps the target fps down (min [minFps]).
const fpsAdaptStep = 4;

/// Stats handed to the overlay roughly every 500ms.
class SenderStats {
  const SenderStats({
    required this.tickCount,
    required this.fps,
    required this.droppedTicks,
    required this.avgTickMs,
    required this.layout,
    required this.k,
  });

  final int tickCount;
  final int fps;
  final int droppedTicks;
  final double avgTickMs;
  final LayoutId layout;
  final int k;
}

/// Frame delay for a target fps, rounded to the nearest millisecond.
int computeFrameDelayMs(int targetFps) => (1000 / targetFps).round();

/// Layout best suited to the canvas aspect ratio and size: extreme portrait →
/// column3, extreme landscape → row3, square-ish canvases by how many
/// near-square tiles they can hold (grid9 needs both sides >=
/// [grid9MinCanvasPx], grid4 >= [grid4MinCanvasPx]), otherwise a single tile.
LayoutId suggestLayout(int canvasWidth, int canvasHeight) {
  final aspect = canvasWidth / canvasHeight;
  if (aspect < 0.8) {
    return LayoutId.column3;
  }
  if (aspect > 1.25) {
    return LayoutId.row3;
  }
  final minSide = math.min(canvasWidth, canvasHeight);
  if (minSide >= grid9MinCanvasPx) {
    return LayoutId.grid9;
  }
  if (minSide >= grid4MinCanvasPx) {
    return LayoutId.grid4;
  }
  return LayoutId.single;
}

/// Effective fps ceiling for a transfer: layout cap AND display-refresh cap.
int _effectiveFpsFor(TransferSettings settings) {
  final fpsCeiling = math.min(
    layoutMaxFps[settings.layout]!,
    settings.highRefresh ? 30 : 24,
  );
  return math.min(settings.targetFps, fpsCeiling);
}

/// Pacing decision for one transfer on one canvas: tiles, fps caps, suggested
/// layout.
({
  int tilesPerFrame,
  int fpsCeiling,
  int effectiveFps,
  LayoutId suggestedLayout,
})
resolvePacing(TransferSettings settings, int canvasWidth, int canvasHeight) {
  final layout = layouts[settings.layout]!;
  final fpsCeiling = math.min(
    layoutMaxFps[settings.layout]!,
    settings.highRefresh ? 30 : 24,
  );
  return (
    tilesPerFrame: layout.cols * layout.rows,
    fpsCeiling: fpsCeiling,
    effectiveFps: math.min(settings.targetFps, fpsCeiling),
    suggestedLayout: suggestLayout(canvasWidth, canvasHeight),
  );
}

/// Integer pixels per module (floored, min 1) so modules stay crisp —
/// sub-pixel scaling anti-aliases modules and lowers decode reliability.
/// Inlined from the PWA's `qr/render.ts`; reconcile against the shared
/// `lib/qr` module once it lands (T3.4).
int _integerScalePx(int modules, int targetPx) =>
    math.max(1, targetPx ~/ modules);

/// Per-cell pixel geometry for a layout on a canvas, with an integer ppm.
({int cellW, int cellH, int ppm}) computeLayoutGeometry(
  int canvasWidth,
  int canvasHeight,
  LayoutId layout,
  int version, {
  int quietZone = 4,
}) {
  final grid = layouts[layout]!;
  final cellW = canvasWidth ~/ grid.cols;
  final cellH = canvasHeight ~/ grid.rows;
  final ppm = _integerScalePx(
    version * 4 + 17 + 2 * quietZone,
    math.min(cellW, cellH),
  );
  return (cellW: cellW, cellH: cellH, ppm: ppm);
}

/// Expected broadcast rate in bytes/second: effective fps x data tiles per
/// tick x symbol size. One of every 32 ticks is the metadata re-broadcast, so
/// data tiles per tick = tilesPerFrame - 1/32; repair overhead (~1.0x) is a
/// transfer-level cost and is not subtracted here.
double estimateThroughput(TransferSettings settings) {
  final layout = layouts[settings.layout]!;
  final tilesPerFrame = layout.cols * layout.rows;
  final symbolSize = bytesPerTile[settings.bytesPerTile]!.symbolSize;
  return _effectiveFpsFor(settings) *
      (tilesPerFrame - 1 / metadataRebroadcastEvery) *
      symbolSize;
}

/// Expected wall time to broadcast `compressedSize` bytes at the estimated
/// rate.
double estimateEtaSeconds(TransferSettings settings, int compressedSize) =>
    compressedSize / estimateThroughput(settings);

/// Whether measured encode+render work (`encodeMs`) fits inside one frame
/// delay with an overhead margin (default [defaultOverheadFactor]) — the
/// budget check the loop uses to decide when to throttle the frame rate down.
bool renderBudgetOk(
  int encodeMs,
  int frameDelayMs, [
  double overheadFactor = defaultOverheadFactor,
]) {
  return encodeMs * overheadFactor <= frameDelayMs;
}

/// Steps the frame rate down by [fpsAdaptStep] when encode+render overran the
/// frame budget, floored at [minFps]. Monotonic — a device that falls behind
/// stays throttled, so the broadcast rate stays stable.
int adaptFps(int currentFps, int workMs, int frameDelayMs) {
  return renderBudgetOk(workMs, frameDelayMs)
      ? currentFps
      : math.max(minFps, currentFps - fpsAdaptStep);
}

/// Deterministic round-robin pick of `tilesPerFrame` packet indices to show on
/// a tick. The pool is the k source esis 0..k-1 followed by the
/// `repairAvailable` repair esis k..k+repairAvailable-1; frame `frameIndex`
/// starts at `frameIndex * tilesPerFrame` mod pool size and walks forward, so
/// consecutive frames never repeat within a frame and the whole pool is
/// covered before the sequence wraps. No randomness — the broadcast pattern is
/// a pure function of frameIndex, which is what lets receivers join
/// mid-broadcast and see a steady stream of distinct packets.
List<int> nextEsiRoundRobin(
  int k,
  int repairAvailable,
  int frameIndex,
  int tilesPerFrame,
) {
  final poolSize = k + repairAvailable;
  if (poolSize <= 0) {
    return [];
  }
  final start = (frameIndex * tilesPerFrame) % poolSize;
  return List<int>.generate(
    tilesPerFrame,
    (i) => (start + i) % poolSize,
    growable: false,
  );
}

/// Deterministic packet source for the broadcast loop: source frames come
/// straight from the prepared transfer; repair frames are generated lazily in
/// one batch on first use and cached (the first repair tick pays a one-time
/// cost, every later repair esi is free).
///
/// Decoupled from the pipeline's `PreparedTransfer` via callbacks so this
/// module stays pure-Dart and testable; the pipeline task (T3.3) wires the
/// real transfer in.
class FramePool {
  FramePool({
    required this.k,
    required List<Uint8List> Function() dataFrames,
    required List<Uint8List> Function(int count) repairFrames,
  }) : _dataFrames = dataFrames,
       _repairFrames = repairFrames;

  /// The k source symbols.
  final int k;

  final List<Uint8List> Function() _dataFrames;
  final List<Uint8List> Function(int count) _repairFrames;
  List<Uint8List>? _repairCache;

  /// Repair symbols available beyond k: ceil(k * [repairExtraFactor]) +
  /// [repairExtraMin].
  int get repairAvailable => (k * repairExtraFactor).ceil() + repairExtraMin;

  /// Full wire-frame bytes for esi; esi >= k resolves into the repair cache.
  Uint8List frameBytes(int esi) {
    if (esi < k) {
      final frames = _dataFrames();
      if (esi >= frames.length) {
        throw RangeError('source frame esi $esi missing');
      }
      return frames[esi];
    }
    final repairIdx = esi - k;
    final repairCache = _repairCache ??= _repairFrames(repairAvailable);
    if (repairIdx >= repairCache.length) {
      throw RangeError('repair frame esi $esi missing');
    }
    return repairCache[repairIdx];
  }
}

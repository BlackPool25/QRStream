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
  LayoutId.column2: 30,
  LayoutId.row2: 30,
  LayoutId.column3: 30,
  LayoutId.row3: 30,
  LayoutId.grid4: 30,
  LayoutId.grid9: 24,
};

/// Min square-canvas side (px) at which the 2x2 grid is worthwhile.
const grid4MinCanvasPx = 800;

/// Min square-canvas side (px) at which the 3x3 grid is worthwhile.
const grid9MinCanvasPx = 1800;

/// Min canvas min-side (px) at which the 3-tile column/row layouts are
/// worthwhile; a portrait/landscape canvas below this is suggested the 2-tile
/// dual-lane layout instead.
const column2MinCanvasPx = 480;
const row2MinCanvasPx = 480;

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
/// column3 (or column2 below [column2MinCanvasPx]), extreme landscape → row3
/// (or row2 below [row2MinCanvasPx]), square-ish canvases by how many
/// near-square tiles they can hold (grid9 needs both sides >=
/// [grid9MinCanvasPx], grid4 >= [grid4MinCanvasPx]), otherwise a single tile.
LayoutId suggestLayout(int canvasWidth, int canvasHeight) {
  final aspect = canvasWidth / canvasHeight;
  final minSide = math.min(canvasWidth, canvasHeight);
  if (aspect < 0.8) {
    return minSide < column2MinCanvasPx ? LayoutId.column2 : LayoutId.column3;
  }
  if (aspect > 1.25) {
    return minSide < row2MinCanvasPx ? LayoutId.row2 : LayoutId.row3;
  }
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

/// Data symbols shown per display tick, net of the metadata re-broadcast
/// (one of every [metadataRebroadcastEvery] ticks carries META instead of a
/// DATA frame). The dual-lane layouts show exactly one new symbol per tick (2
/// tiles, each holding for 2 ticks — the same rate as a single tile), so they
/// must not be charged `tilesPerFrame`; META replaces the lane that would
/// otherwise update.
double symbolsPerTickFor(LayoutId layout) {
  if (isDualLaneLayout(layout)) {
    return 1 - 1 / metadataRebroadcastEvery;
  }
  final tile = layouts[layout]!;
  return tile.cols * tile.rows - 1 / metadataRebroadcastEvery;
}

/// Expected broadcast rate in bytes/second: effective fps x data symbols per
/// tick x symbol size. Repair overhead (~1.0x) is a transfer-level cost and is
/// not subtracted here.
double estimateThroughput(TransferSettings settings) {
  final symbolSize = bytesPerTile[settings.bytesPerTile]!.symbolSize;
  return _effectiveFpsFor(settings) *
      symbolsPerTickFor(settings.layout) *
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

/// Whether `layout` is one of the dual-lane position-stable layouts: two tiles
/// at fixed slots, each updating at half the display rate (see
/// [nextEsiDualLane]).
bool isDualLaneLayout(LayoutId layout) =>
    layout == LayoutId.row2 || layout == LayoutId.column2;

/// Dual-lane schedule: lane 0 updates on EVEN ticks, lane 1 on ODD ticks; each
/// lane holds its QR for exactly 2 ticks (half the display rate). Slot i always
/// carries lane i (position-stable). The two walkers are phase-offset by
/// poolSize/2 so the lanes never show the same esi on the same tick.
///
/// Pure function of tickIndex — the broadcast controller relies on
/// `_requestFrame` (encode lookahead) and `_frameWithEsis` (drain) recomputing
/// the SAME esis, exactly like [nextEsiRoundRobin].
///
/// Pool size must be >= 3 for the phase offset to keep the lanes distinct
/// (k + repairAvailable is always well above that in practice). With an odd
/// pool size `P~/2` floors, but the offset is still nonzero mod P, so the
/// lanes remain distinct on every tick.
List<int> nextEsiDualLane(int k, int repairAvailable, int tickIndex) {
  final poolSize = k + repairAvailable;
  if (poolSize <= 0) {
    return [];
  }
  final lane0 = (tickIndex ~/ 2) % poolSize;
  final lane1 = ((tickIndex + 1) ~/ 2 + poolSize ~/ 2) % poolSize;
  return [lane0, lane1];
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

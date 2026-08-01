/// Sender transfer settings: defaults, validation, display refresh-rate
/// detection and human-readable labels. Pure Dart port of
/// `src/sender/settings.ts`; display-loop concerns (rAF / Ticker) stay out of
/// this file — the Flutter app wires [detectRefreshRateCore] to a Ticker.
library;

import 'dart:async';

import 'package:qr_transfer_core/protocol/constants.dart';

/// Default transfer settings, matching the PWA's `DEFAULT_TRANSFER_SETTINGS`.
const TransferSettings defaultTransferSettings = TransferSettings(
  bytesPerTile: BytesPerTileId.oneK,
  layout: LayoutId.grid4,
  targetFps: 15,
  highRefresh: false,
);

/// Validates settings at the UI/pipeline boundary, throwing [ArgumentError] on
/// an unknown bytesPerTile or layout, a disallowed targetFps or a non-boolean
/// highRefresh. Callers may trust the settings afterwards.
void validateSettings(TransferSettings s) {
  if (!BytesPerTileId.values.contains(s.bytesPerTile)) {
    throw ArgumentError(
      'bytesPerTile must be one of '
      '${BytesPerTileId.values.map((e) => e.id).join(', ')}, '
      'got ${s.bytesPerTile}',
    );
  }
  if (!LayoutId.values.contains(s.layout)) {
    throw ArgumentError(
      'layout must be one of ${LayoutId.values.join(', ')}, got ${s.layout}',
    );
  }
  if (!const {12, 15, 24, 30}.contains(s.targetFps)) {
    throw ArgumentError(
      'targetFps must be one of 12, 15, 24, 30, got ${s.targetFps}',
    );
  }
  // Sound Dart guarantees s.highRefresh is a bool, so this branch is
  // statically dead; it defends the future untyped JSON boundary (port parity
  // with the PWA), where a reconstructed value could hold anything.
  // ignore: dead_code, unnecessary_type_check
  if (s.highRefresh is! bool) {
    throw ArgumentError('highRefresh must be a boolean, got ${s.highRefresh}');
  }
}

/// Classifies a measured frame count over a window into a display refresh
/// rate: >=105 → 120, >=75 → 90, else 60; an elapsed of <=0 resolves 60.
/// Uses the PWA's exact thresholds.
int classifyRefreshRate({required int frames, required int elapsedMs}) {
  if (elapsedMs <= 0) return 60;
  final rate = frames * 1000 / elapsedMs;
  return rate >= 105
      ? 120
      : rate >= 75
      ? 90
      : 60;
}

/// Refresh-rate probe: counts frames scheduled via [scheduleFrame] over a
/// [windowMs] window and classifies the measured rate. Always cancels the
/// trailing pending frame so the probe leaves nothing scheduled. Port of the
/// PWA's `detectRefreshRateCore` ([scheduleFrame] mirrors `requestAnimationFrame`
/// in that it returns a token, [cancelFrame] mirrors `cancelAnimationFrame`).
Future<int> detectRefreshRateCore({
  required int Function(void Function() onFrame) scheduleFrame,
  required void Function(int token) cancelFrame,
  required int Function() now,
  int windowMs = 400,
}) {
  final completer = Completer<int>();
  final start = now();
  var ticks = 0;
  var lastToken = 0;

  void frame() {
    final elapsed = now() - start;
    ticks += 1;
    // Register the next frame up front so the trailing pending one can be
    // canceled when the window closes.
    lastToken = scheduleFrame(frame);
    if (elapsed <= 0) {
      cancelFrame(lastToken);
      completer.complete(60);
      return;
    }
    if (elapsed < windowMs) return;
    cancelFrame(lastToken);
    completer.complete(classifyRefreshRate(frames: ticks, elapsedMs: elapsed));
  }

  lastToken = scheduleFrame(frame);
  return completer.future;
}

/// Human-readable transfer label, e.g. "V27 · 2×2". Dimensions read as
/// "rows × columns" (standard grid notation): the vertical column layout
/// (1 column of 3 tiles) shows as "3×1", the horizontal row as "1×3". The
/// maps in constants.dart are total over their enum keys, so the lookups
/// cannot fail.
String transferLabel(TransferSettings s) {
  final profile = bytesPerTile[s.bytesPerTile]!;
  final tile = layouts[s.layout]!;
  return 'V${profile.version} · ${tile.rows}×${tile.cols}';
}

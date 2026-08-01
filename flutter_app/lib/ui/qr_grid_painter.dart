/// Grid QR painter for the broadcast display — paints the controller's tile
/// list as white QR modules on an always-dark espresso background.
///
/// Port of the PWA's `renderTiles` (src/qr/render.ts): the layout splits the
/// canvas into cols×rows cells, each tile is centered in its cell with a
/// quiet-zone margin, and modules are drawn at integer pixels per module
/// (computed exactly like `computeLayoutGeometry`) so they stay crisp in the
/// receiver's camera — sub-pixel anti-aliasing is a decode killer. Null tiles
/// (failed encodes) leave their cell on the espresso background.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';

/// QR spec minimum quiet zone, in modules (parity with the PWA).
const int minQuietZone = 4;

/// Paint a broadcast frame: [tiles] laid out per [layout], each QR's dark
/// modules filled white on an espresso background. Repaints when [repaint]
/// fires (the controller's frame signal).
class QrGridPainter extends CustomPainter {
  QrGridPainter({
    required this.tiles,
    required this.layout,
    required this.version,
    this.quietZone = minQuietZone,
    super.repaint,
  });

  /// Tiles for the current frame, in row-major cell order (cell i at
  /// col = i % cols, row = i ~/ cols).
  final List<QrMatrix?> tiles;

  /// Tile arrangement (cols × rows).
  final LayoutId layout;

  /// QR version every tile was encoded at (drives the module count).
  final int version;

  /// Quiet-zone width in modules.
  final int quietZone;

  /// Always-dark espresso background — the receiver camera decodes crisp
  /// white modules off it.
  static const Color espresso = Color(0xFF161312);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = espresso);

    final grid = layouts[layout]!;
    final cellW = size.width ~/ grid.cols;
    final cellH = size.height ~/ grid.rows;
    // Integer px/module, floored at 1 — identical to computeLayoutGeometry.
    final modules = version * 4 + 17 + 2 * quietZone;
    final ppm = math.max(1, math.min(cellW, cellH) ~/ modules);

    final white = Paint()..color = const Color(0xFFFFFFFF);
    for (var i = 0; i < tiles.length; i++) {
      final matrix = tiles[i];
      if (matrix == null) continue; // failed tile → bare espresso cell
      final col = i % grid.cols;
      final row = i ~/ grid.cols;
      final tileSide = (matrix.size + 2 * quietZone) * ppm;
      final ox = col * cellW + (cellW - tileSide) ~/ 2;
      final oy = row * cellH + (cellH - tileSide) ~/ 2;
      final m = matrix.size;
      for (var my = 0; my < m; my++) {
        final base = my * m;
        for (var mx = 0; mx < m; mx++) {
          if (matrix.modules[base + mx] == 1) {
            canvas.drawRect(
              Rect.fromLTWH(
                (ox + (mx + quietZone) * ppm).toDouble(),
                (oy + (my + quietZone) * ppm).toDouble(),
                ppm.toDouble(),
                ppm.toDouble(),
              ),
              white,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(QrGridPainter oldDelegate) =>
      oldDelegate.tiles != tiles ||
      oldDelegate.layout != layout ||
      oldDelegate.version != version ||
      oldDelegate.quietZone != quietZone;
}

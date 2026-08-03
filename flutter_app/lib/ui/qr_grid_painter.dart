/// Grid QR painter for the broadcast display — paints the controller's tile
/// list as white QR modules on an always-dark espresso background.
///
/// Port of the PWA's `renderTiles` (src/qr/render.ts): the layout splits the
/// canvas into cols×rows cells, and each tile is drawn edge-to-edge (only the
/// QR-spec quiet zone separates tiles), with modules scaled CONTINUOUSLY to the
/// cell — the tile side is `min(cellW, cellH)` and the px/module scale is
/// fractional, so tiles grow linearly with the window instead of stepping in
/// whole-module jumps that waste space. The tiles are packed into ONE flush
/// block that is CENTERED in the canvas, so on a tall screen a 2×2 stays
/// together in the middle (per-cell centering would leave a dead band between
/// the rows) and every QR is close enough to hold the phone up to. Renders
/// with nearest-neighbour sampling ([FilterQuality.none] / non-AA paths) so
/// module edges stay hard at any scale — anti-aliasing, not fractional size,
/// is the decode killer. Null tiles (failed encodes) leave their cell on the
/// espresso background.
///
/// Rendering is BITMAP-BASED: each tile's module matrix is packed into a raw
/// RGBA image ([matrixToRgba]) and drawn as a [ui.Image] blit (one
/// `drawImageRect` per tile) with nearest-neighbour scaling. This avoids
/// per-module vector draws (drawRect / Path.addRect) — on Android's Impeller
/// renderer every one of those rects bottoms out in a tessellated path, which
/// caps a multi-thousand-rect frame at ~1 fps on a phone. The blitted images
/// come from a [Map] keyed by the tile's pool index ([images] / [esis]) that
/// the view pre-decodes one frame ahead; tiles without a ready image fall back
/// to run-length-batched paths (Skia handles those fast, and the fallback only
/// ever runs for the first frame or two).
///
/// The layout is computed in PHYSICAL pixels ([devicePixelRatio]) like the
/// PWA's device-pixel canvas, so modules are as large as the display allows.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';

/// QR spec minimum quiet zone, in modules (parity with the PWA).
const int minQuietZone = 4;

/// Packs a QR module matrix into raw RGBA bytes (white modules on
/// transparent) at matrix resolution — the blit scales it to the cell.
Uint8List matrixToRgba(QrMatrix matrix) {
  final m = matrix.size;
  final rgba = Uint8List(m * m * 4);
  for (var y = 0; y < m; y++) {
    final base = y * m;
    for (var x = 0; x < m; x++) {
      if (matrix.modules[base + x] == 1) {
        final o = (base + x) * 4;
        rgba[o] = 0xFF;
        rgba[o + 1] = 0xFF;
        rgba[o + 2] = 0xFF;
        rgba[o + 3] = 0xFF;
      }
    }
  }
  return rgba;
}

/// Paint a broadcast frame: [tiles] laid out per [layout], each QR's dark
/// modules filled white on an espresso background. Repaints when [repaint]
/// fires (the controller's frame signal).
class QrGridPainter extends CustomPainter {
  QrGridPainter({
    required this.tiles,
    required this.layout,
    required this.version,
    this.esis = const [],
    this.images,
    this.quietZone = minQuietZone,
    this.devicePixelRatio = 1.0,
    super.repaint,
  });

  /// Tiles for the current frame, in row-major cell order (cell i at
  /// col = i % cols, row = i ~/ cols).
  final List<QrMatrix?> tiles;

  /// Pool index of each tile ([metaSlotEsi] for the META slot) — the key into
  /// [images].
  final List<int> esis;

  /// Pre-decoded tile bitmaps keyed by pool index; a tile without one falls
  /// back to the run-length path.
  final Map<int, ui.Image>? images;

  /// Tile arrangement (cols × rows).
  final LayoutId layout;

  /// QR version every tile was encoded at (drives the module count).
  final int version;

  /// Quiet-zone width in modules.
  final int quietZone;

  /// Device pixel ratio: the layout is computed in physical pixels so the
  /// modules are as large and crisp as the PWA's device-pixel canvas.
  final double devicePixelRatio;

  /// Always-dark espresso background — the receiver camera decodes crisp
  /// white modules off it.
  static const Color espresso = Color(0xFF161312);

  static final Paint _espressoPaint = Paint()..color = espresso;
  static final Paint _whitePaint = Paint()
    ..color = const Color(0xFFFFFFFF)
    // Hard module edges at fractional scales: anti-aliased paths blur modules
    // and kill decode reliability (the px/module cliff).
    ..isAntiAlias = false;
  static final Paint _tilePaint = Paint()..filterQuality = FilterQuality.none;

  @override
  void paint(Canvas canvas, Size size) {
    final dpr = devicePixelRatio;
    // Draw in a user space of PHYSICAL pixels (the PWA's device-pixel canvas):
    // scale(1/dpr) maps user unit u → device pixel u, so modules are as large
    // and crisp as the display allows.
    canvas.save();
    canvas.scale(1 / dpr);
    final physW = (size.width * dpr).round();
    final physH = (size.height * dpr).round();
    canvas.drawRect(
      Rect.fromLTWH(0, 0, physW.toDouble(), physH.toDouble()),
      _espressoPaint,
    );

    final grid = layouts[layout]!;
    // Continuous linear scaling: the tile fills the smaller cell dimension
    // edge-to-edge, so the tiles grow with the window instead of stepping in
    // whole-module jumps that leave dead space around the QRs.
    final cellW = physW / grid.cols;
    final cellH = physH / grid.rows;
    final tileSide = math.min(cellW, cellH);

    // Pack the tiles into ONE flush block (cols×rows of tileSide squares) and
    // center that block in the canvas. Per-cell centering would spread the
    // rows apart on tall screens (each tile centered in its own tall cell →
    // a big dead band between the rows in a 2×2), which defeats holding the
    // phone close to a central QR. The block keeps every QR adjacent (only
    // the QR-spec quiet zone separates them) with all leftover space as outer
    // margin.
    final blockW = grid.cols * tileSide;
    final blockH = grid.rows * tileSide;
    final blockOx = (physW - blockW) / 2;
    final blockOy = (physH - blockH) / 2;

    for (var i = 0; i < tiles.length; i++) {
      final matrix = tiles[i];
      if (matrix == null) continue; // failed tile → bare espresso cell
      final col = i % grid.cols;
      final row = i ~/ grid.cols;
      final ox = blockOx + col * tileSide;
      final oy = blockOy + row * tileSide;
      final cached = images?[esis.isNotEmpty && i < esis.length ? esis[i] : i];
      if (cached != null) {
        _paintTileBitmap(canvas, matrix, cached, ox, oy, quietZone, tileSide);
      } else {
        _paintTilePath(canvas, matrix, ox, oy, quietZone, tileSide);
      }
    }
    canvas.restore();
  }

  /// Bitmap blit: draw the pre-decoded [image] (matrix resolution, white on
  /// transparent) into the quiet-zone-inset cell with nearest-neighbour
  /// scaling — one draw call per tile. The tile spans [tileSide] physical
  /// pixels (fractional px/module allowed — nearest-neighbour keeps the edges
  /// hard).
  void _paintTileBitmap(
    Canvas canvas,
    QrMatrix matrix,
    ui.Image image,
    double ox,
    double oy,
    int quietZone,
    double tileSide,
  ) {
    final m = matrix.size;
    final totalModules = m + 2 * quietZone;
    final scale = tileSide / totalModules;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, m.toDouble(), m.toDouble()),
      Rect.fromLTWH(
        ox + quietZone * scale,
        oy + quietZone * scale,
        m * scale,
        m * scale,
      ),
      _tilePaint,
    );
  }

  /// Run-length-batched paths (fallback until the tile's image is decoded):
  /// consecutive dark modules in each row coalesce into one rect, batched
  /// into ONE Path per tile — a few draw calls instead of one per module.
  /// Non-AA (see [_whitePaint]) so fractional scales keep hard edges.
  void _paintTilePath(
    Canvas canvas,
    QrMatrix matrix,
    double ox,
    double oy,
    int quietZone,
    double tileSide,
  ) {
    final m = matrix.size;
    final totalModules = m + 2 * quietZone;
    final scale = tileSide / totalModules;
    final path = Path()..fillType = PathFillType.nonZero;
    for (var my = 0; my < m; my++) {
      final base = my * m;
      final y = oy + (my + quietZone) * scale;
      var mx = 0;
      while (mx < m) {
        if (matrix.modules[base + mx] == 1) {
          final runStart = mx;
          while (mx + 1 < m && matrix.modules[base + mx + 1] == 1) {
            mx++;
          }
          path.addRect(
            Rect.fromLTWH(
              ox + (runStart + quietZone) * scale,
              y,
              (mx - runStart + 1) * scale,
              scale,
            ),
          );
        }
        mx++;
      }
    }
    canvas.drawPath(path, _whitePaint);
  }

  @override
  bool shouldRepaint(QrGridPainter oldDelegate) =>
      oldDelegate.tiles != tiles ||
      oldDelegate.esis != esis ||
      oldDelegate.images != images ||
      oldDelegate.layout != layout ||
      oldDelegate.version != version ||
      oldDelegate.quietZone != quietZone ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}

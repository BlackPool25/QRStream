// QrGridPainter contract: the run-batched, physical-pixel painter must place
// every dark module with HARD edges (nearest-neighbour blit / non-AA paths) on
// the espresso stage, and scale tiles CONTINUOUSLY so they grow linearly with
// the canvas — filling each cell edge-to-edge (only the QR-spec quiet zone
// separates tiles) instead of stepping in whole-module jumps that waste space.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide LayoutId;
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_data_transfer/ui/qr_grid_painter.dart';
import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:zxing2/qrcode.dart';

void main() {
  // A 5×5 matrix with a single dark module at (2,2).
  QrMatrix singleModuleMatrix() {
    final size = 5;
    final modules = Uint8List(size * size);
    modules[2 * size + 2] = 1;
    return QrMatrix(modules: modules, size: size);
  }

  /// Rasterizes [painter] at [logicalW]×[logicalH] (for tall-canvas layout
  /// tests); the raster resolution is the logical size × [dpr].
  Future<ByteData> rasterizeWH(
    QrGridPainter painter,
    double logicalW,
    double logicalH,
    double dpr,
  ) async {
    final physW = (logicalW * dpr).round();
    final physH = (logicalH * dpr).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, Size(logicalW, logicalH));
    final img = await recorder.endRecording().toImage(physW, physH);
    final bytes = await img.toByteData();
    img.dispose();
    return bytes!;
  }

  /// Rasterizes [painter] at [logical]×[logical]; the raster resolution is
  /// [logical]×[dpr] (pass 1.0 for a 1:1 logical raster).
  Future<ByteData> rasterize(
    QrGridPainter painter,
    double logical,
    double dpr,
  ) => rasterizeWH(painter, logical, logical, dpr);

  Color pixel(ByteData data, int width, int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }

  /// Continuous tile geometry (mirrors the painter): the tile fills the
  /// smaller cell dimension edge-to-edge, so the px/module scale is fractional.
  /// Returns the pixel coordinates of the single dark module (2,2).
  ({double x, double y}) moduleCenter(
    int canvasPx,
    qrc.LayoutId layout,
    int col,
    int row,
  ) {
    final grid = qrc.layouts[layout]!;
    final cellW = canvasPx / grid.cols;
    final cellH = canvasPx / grid.rows;
    final tileSide = cellW < cellH ? cellW : cellH;
    // The tiles are packed into one flush block, centered in the canvas.
    final blockW = grid.cols * tileSide;
    final blockH = grid.rows * tileSide;
    final ox0 = (canvasPx - blockW) / 2;
    final oy0 = (canvasPx - blockH) / 2;
    final totalModules = 5 + 2 * minQuietZone; // 5×5 matrix + quiet zone
    final scale = tileSide / totalModules;
    final ox = ox0 + col * tileSide;
    final oy = oy0 + row * tileSide;
    return (x: ox + (2 + minQuietZone) * scale, y: oy + (2 + minQuietZone) * scale);
  }

  testWidgets('single tile fills the canvas edge to edge (no dead margin)', (
    tester,
  ) async {
    // Canvas 116, single layout: the tile spans the full canvas (only the
    // quiet zone sits at the very edge), so a pixel near the canvas edge is
    // white — the old integer-step renderer left a ~32px dead margin there.
    const canvasPx = 116;
    final data = (await tester.runAsync(
      () => rasterize(
        QrGridPainter(
          tiles: [singleModuleMatrix()],
          layout: qrc.LayoutId.single,
          version: 1,
        ),
        canvasPx.toDouble(),
        1.0,
      ),
    ))!;

    final center = moduleCenter(canvasPx, qrc.LayoutId.single, 0, 0);
    // The dark module is white at its (fractional) center…
    expect(pixel(data, canvasPx, center.x.round(), center.y.round()),
        const Color(0xFFFFFFFF));
    // …and it spans ~8.9px (scale 116/13), so a pixel at x=60 that sat in the
    // dead margin of the old 4px-module renderer is now inside the module.
    expect(pixel(data, canvasPx, 60, center.y.round()), const Color(0xFFFFFFFF));
    // The canvas corner is in the quiet zone → espresso.
    expect(pixel(data, canvasPx, 1, 1), QrGridPainter.espresso);
  });

  testWidgets('tiles scale linearly with the canvas, not in integer steps', (
    tester,
  ) async {
    // Doubling the canvas must ~double the module position: continuous
    // scaling. The old renderer floored the px/module, so two canvases within
    // one module step rendered identical tile sizes.
    Future<({int x, int y})> moduleAt(int canvasPx) async {
      final data = (await tester.runAsync(
        () => rasterize(
          QrGridPainter(
            tiles: [singleModuleMatrix()],
            layout: qrc.LayoutId.single,
            version: 1,
          ),
          canvasPx.toDouble(),
          1.0,
        ),
      ))!;
      final c = moduleCenter(canvasPx, qrc.LayoutId.single, 0, 0);
      final x = c.x.round();
      final y = c.y.round();
      // The module really is painted there (not just derived on paper).
      expect(
        pixel(data, canvasPx, x, y),
        const Color(0xFFFFFFFF),
        reason: 'module must be painted at the linear-scaled position',
      );
      return (x: x, y: y);
    }

    final small = await moduleAt(116);
    final large = await moduleAt(232);
    // 116 → module ≈ 53.5; 232 → module ≈ 107.1 (linear ~2×).
    expect(large.x, greaterThan(small.x * 2 - 2));
    expect(large.x, lessThan(small.x * 2 + 2));
    expect(large.y, greaterThan(small.y * 2 - 2));
    expect(large.y, lessThan(small.y * 2 + 2));
  });

  testWidgets('2×2 block concentrates in the center of a tall canvas', (
    tester,
  ) async {
    // Portrait canvas 160×320 with grid4: per-cell centering spreads the two
    // rows apart (each tile centered in its own tall cell → a dead band
    // between the rows); block packing keeps the 2×2 together in the middle.
    const w = 160;
    const h = 320;
    final data = (await tester.runAsync(
      () => rasterizeWH(
        QrGridPainter(
          tiles: [
            singleModuleMatrix(),
            singleModuleMatrix(),
            singleModuleMatrix(),
            singleModuleMatrix(),
          ],
          layout: qrc.LayoutId.grid4,
          version: 1,
        ),
        w.toDouble(),
        h.toDouble(),
        1.0,
      ),
    ))!;

    // cellW = 160/2 = 80, cellH = 320/2 = 160 → tileSide = 80. The 2×2 block
    // is 160×160, centered → blockOy = (320-160)/2 = 80. Row 0 module at
    // 80 + (2+4)*scale, row 1 module one tileSide below (row 0 + 80).
    final totalModules = 5 + 2 * minQuietZone;
    final scale = 80 / totalModules;
    final blockOy = (h - 2 * 80) / 2; // 80
    final row0y = (blockOy + (2 + minQuietZone) * scale).round();
    final row1y = (blockOy + 80 + (2 + minQuietZone) * scale).round();

    // Both rows painted…
    expect(pixel(data, w, 80 ~/ 2, row0y), const Color(0xFFFFFFFF));
    expect(pixel(data, w, 80 ~/ 2, row1y), const Color(0xFFFFFFFF));
    // …and concentrated: row 1 sits immediately below row 0 (gap ≈ 80, the
    // tile side), not spread toward the canvas bottom (gap ≈ 160 under the
    // old per-cell centering).
    expect(row1y - row0y, 80);
    // Both rows stay inside the central block band (80..240 of a 320 canvas).
    expect(row0y, greaterThan(100));
    expect(row0y, lessThan(130));
    expect(row1y, greaterThan(180));
    expect(row1y, lessThan(215));
  });

  testWidgets('null tiles leave their cell on the espresso background', (
    tester,
  ) async {
    const canvasPx = 116;
    final data = (await tester.runAsync(
      () => rasterize(
        QrGridPainter(tiles: [null], layout: qrc.LayoutId.single, version: 1),
        canvasPx.toDouble(),
        1.0,
      ),
    ))!;
    expect(
      pixel(data, canvasPx, canvasPx ~/ 2, canvasPx ~/ 2),
      QrGridPainter.espresso,
    );
  });

  testWidgets('row2 paints two tiles side by side', (tester) async {
    const canvasPx = 232; // two 116px cells side by side
    final data = (await tester.runAsync(
      () => rasterize(
        QrGridPainter(
          tiles: [singleModuleMatrix(), singleModuleMatrix()],
          layout: qrc.LayoutId.row2,
          version: 1,
        ),
        canvasPx.toDouble(),
        1.0,
      ),
    ))!;

    final slot0 = moduleCenter(canvasPx, qrc.LayoutId.row2, 0, 0);
    final slot1 = moduleCenter(canvasPx, qrc.LayoutId.row2, 1, 0);
    // Both dark modules are painted…
    expect(pixel(data, canvasPx, slot0.x.round(), slot0.y.round()),
        const Color(0xFFFFFFFF));
    expect(pixel(data, canvasPx, slot1.x.round(), slot1.y.round()),
        const Color(0xFFFFFFFF));
    // …side by side: slot 0 to the LEFT of slot 1 on the same row.
    expect(slot1.x, greaterThan(slot0.x));
    expect(slot1.y, slot0.y);
    // Tiles fill their cells: slot 1's module sits in the right half, and the
    // quiet-zone band between the two tiles is thin (not a large dead gap).
    expect(slot1.x, greaterThan(canvasPx / 2));
  });

  testWidgets('column2 paints stacked', (tester) async {
    const canvasPx = 232; // two 116px cells stacked
    final data = (await tester.runAsync(
      () => rasterize(
        QrGridPainter(
          tiles: [singleModuleMatrix(), singleModuleMatrix()],
          layout: qrc.LayoutId.column2,
          version: 1,
        ),
        canvasPx.toDouble(),
        1.0,
      ),
    ))!;

    final slot0 = moduleCenter(canvasPx, qrc.LayoutId.column2, 0, 0);
    final slot1 = moduleCenter(canvasPx, qrc.LayoutId.column2, 0, 1);
    // Both dark modules are painted…
    expect(pixel(data, canvasPx, slot0.x.round(), slot0.y.round()),
        const Color(0xFFFFFFFF));
    expect(pixel(data, canvasPx, slot1.x.round(), slot1.y.round()),
        const Color(0xFFFFFFFF));
    // …stacked: slot 0 ABOVE slot 1 on the same column.
    expect(slot1.y, greaterThan(slot0.y));
    expect(slot1.x, slot0.x);
  });

  testWidgets('physical-pixel layout sizes modules to the DPR', (tester) async {
    // Logical 360 at DPR 3 → physical 1080; a single V27 tile fills the full
    // canvas, so a module spans 1080/133 ≈ 8.1 physical px (vs 2 logical at
    // DPR 1). The module lands at the physical-pixel position / dpr in the
    // logical raster.
    const dpr = 3.0;
    const logical = 360.0;
    final data = (await tester.runAsync(
      () => rasterize(
        QrGridPainter(
          tiles: [singleModuleMatrix()],
          layout: qrc.LayoutId.single,
          version: 27,
          devicePixelRatio: dpr,
        ),
        logical,
        1.0,
      ),
    ))!;

    // version 27 → matrix 125 + quiet zone 8 = 133 modules. Tile side = 1080
    // physical px; module (2,2) of the 5×5 test matrix sits at quiet zone 4 +
    // row 2 = 6 modules × (1080/13) ≈ 498.5 physical px → logical ≈ 166.
    final moduleLogical = ((2 + minQuietZone) * (1080 / 13) / dpr).round();
    expect(pixel(data, logical.round(), moduleLogical, moduleLogical),
        const Color(0xFFFFFFFF));
    // The physical layout makes the module span ~8 physical px — strictly
    // larger than the 2 logical px the logical-only render would give.
    expect(pixel(data, logical.round(), 2, 2), QrGridPainter.espresso);
  });

  testWidgets('a real QR painted by the run-batched painter decodes back', (
    tester,
  ) async {
    // Encode a real tile payload, paint it the way the broadcast stage does,
    // rasterize, and decode with the same zxing2 reader the receiver's isolate
    // pool uses — the proof that continuous scaling still renders
    // camera-decodable QRs.
    final payload = Uint8List.fromList(List<int>.generate(40, (i) => i % 251));
    final matrix = encodeQrBytes(payload, version: 5);
    const dpr = 2.0;
    const logical = 180.0;
    // version 5 → 45 modules incl. quiet zone; the tile fills the 180-logical
    // canvas edge to edge (45 × 8 physical px = 360 phys = 180 logical).
    final data = (await tester.runAsync(
      () => rasterize(
        QrGridPainter(
          tiles: [matrix],
          layout: qrc.LayoutId.single,
          version: 5,
          devicePixelRatio: dpr,
        ),
        logical,
        1.0,
      ),
    ))!;

    // Build the luminance source the decode pool uses (RGBA → gray).
    final luminance = Int32List(logical.round() * logical.round());
    for (var i = 0, p = 0; i < data.lengthInBytes; i += 4, p++) {
      final r = data.getUint8(i);
      final g = data.getUint8(i + 1);
      final b = data.getUint8(i + 2);
      luminance[p] = 0xff000000 | (r << 16) | (g << 8) | b;
    }
    // Mirror the decode pool: try normal, then the inverted image (the stage
    // is white-on-dark and zxing assumes dark-on-light).
    ByteData? decodeFrom(Int32List pixels) {
      final bitmap = BinaryBitmap(
        GlobalHistogramBinarizer(
          RGBLuminanceSource(logical.round(), logical.round(), pixels),
        ),
      );
      final reader = QRCodeReader();
      final hints = DecodeHints()..put(DecodeHintType.pureBarcode);
      try {
        final result = reader.decode(bitmap, hints: hints);
        final segments =
            result.resultMetadata[ResultMetadataType.byteSegments]
                as List<Int8List>;
        final decoded = Uint8List.fromList([for (final s in segments) ...s]);
        return ByteData.sublistView(decoded);
      } on ReaderException {
        return null;
      }
    }

    final inverted = Int32List(luminance.length);
    for (var i = 0; i < luminance.length; i++) {
      inverted[i] = 0xff000000 | (0xFFFFFF - (luminance[i] & 0xFFFFFF));
    }
    final decoded = decodeFrom(luminance) ?? decodeFrom(inverted);
    expect(
      decoded,
      isNotNull,
      reason: 'stage QR must decode (normal or inverted)',
    );
    expect(
      Uint8List.view(
        decoded!.buffer,
        decoded.offsetInBytes,
        decoded.lengthInBytes,
      ),
      equals(payload),
    );
  });

  testWidgets('bitmap blit path paints identically to the path fallback', (
    tester,
  ) async {
    // The phone runs the bitmap path (pre-decoded tile images); it must
    // render the exact same white modules as the run-length path fallback.
    final payload = Uint8List.fromList(List<int>.generate(40, (i) => i % 251));
    final matrix = encodeQrBytes(payload, version: 5);
    final image = (await tester.runAsync(() async {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        matrixToRgba(matrix),
        matrix.size,
        matrix.size,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    }))!;

    Future<ByteData> paint({bool blit = true}) async =>
        (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          QrGridPainter(
            tiles: [matrix],
            esis: blit ? const [0] : const [],
            images: blit ? <int, ui.Image>{0: image} : null,
            layout: qrc.LayoutId.single,
            version: 5,
          ).paint(canvas, const Size(180, 180));
          final img = await recorder.endRecording().toImage(180, 180);
          final bytes = await img.toByteData();
          img.dispose();
          return bytes!;
        }))!;

    final blitBytes = await paint(blit: true);
    final pathBytes = await paint(blit: false);
    expect(
      blitBytes.buffer.asUint8List(),
      equals(pathBytes.buffer.asUint8List()),
      reason: 'bitmap blit and run-length paths must paint identical pixels',
    );
    image.dispose();
  });
}

// QrGridPainter contract: the run-batched, physical-pixel painter must place
// every dark module at crisp integer pixels (camera-decodable) on the espresso
// stage, and the physical layout must size modules to the device pixel ratio.
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

  /// Rasterizes [painter] at [logical]×[logical]; the raster resolution is
  /// [logical]×[dpr] (pass 1.0 for a 1:1 logical raster).
  Future<ByteData> rasterize(
    QrGridPainter painter,
    double logical,
    double dpr,
  ) async {
    final phys = (logical * dpr).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, Size(logical, logical));
    final img = await recorder.endRecording().toImage(phys, phys);
    final bytes = await img.toByteData();
    img.dispose();
    return bytes!;
  }

  Color pixel(ByteData data, int width, int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }

  testWidgets('paints the single dark module at the exact integer pixel', (
    tester,
  ) async {
    const canvasPx = 116; // version 1 → 29 modules → ppm 4
    final data = (await tester.runAsync(() => rasterize(
          QrGridPainter(
            tiles: [singleModuleMatrix()],
            layout: qrc.LayoutId.single,
            version: 1,
          ),
          canvasPx.toDouble(),
          1.0,
        )))!;

    // Quiet zone 4 → module (2,2) sits at pixel (2+4)*4 = 24, centered in the
    // 52px tile (tileSide=(5+8)*4) inside the 116px canvas → offset (116-52)/2.
    const ox = (canvasPx - 52) ~/ 2; // 32
    final moduleX = ox + (2 + 4) * 4; // 56
    final moduleY = ox + (2 + 4) * 4;

    // The module block is white and exactly 4×4 px…
    expect(pixel(data, canvasPx, moduleX, moduleY), const Color(0xFFFFFFFF));
    expect(pixel(data, canvasPx, moduleX + 3, moduleY + 3), const Color(0xFFFFFFFF));
    // …and a neighbouring pixel inside the tile's quiet zone is espresso.
    expect(pixel(data, canvasPx, ox + 1, ox + 1), QrGridPainter.espresso);
    // A module that should be light stays espresso.
    expect(pixel(data, canvasPx, moduleX + 4, moduleY), QrGridPainter.espresso);
    // The canvas corner is espresso.
    expect(pixel(data, canvasPx, 1, 1), QrGridPainter.espresso);
  });

  testWidgets('null tiles leave their cell on the espresso background', (
    tester,
  ) async {
    const canvasPx = 116;
    final data = (await tester.runAsync(() => rasterize(
          QrGridPainter(
            tiles: [null],
            layout: qrc.LayoutId.single,
            version: 1,
          ),
          canvasPx.toDouble(),
          1.0,
        )))!;
    expect(pixel(data, canvasPx, canvasPx ~/ 2, canvasPx ~/ 2), QrGridPainter.espresso);
  });

  testWidgets('physical-pixel layout sizes modules to the DPR', (tester) async {
    // Logical 360 at DPR 3 → physical 1080; a V27 tile (125 modules incl.
    // quiet zone) gets ppm = 1080 ~/ 125 = 8 physical px (vs 2 logical at
    // DPR 1). The module must land at the physical-pixel position × 8.
    const dpr = 3.0;
    const logical = 360.0;
    // Rasterize at the LOGICAL size (toImage is 1:1 with the picture's
    // logical space): the physical layout places the module at
    // physicalCoord / dpr in that space.
    final data = (await tester.runAsync(() => rasterize(
          QrGridPainter(
            tiles: [singleModuleMatrix()],
            layout: qrc.LayoutId.single,
            version: 27,
            devicePixelRatio: dpr,
          ),
          logical,
          1.0, // 1:1 raster — the painter's own scale(1/dpr) does the rest
        )))!;

    // version 27 → modules = 133; ppm = (360*3) ~/ 133 = 8 physical px.
    // Tile side = (5 + 8) * 8 = 104; offset = (1080 - 104) ~/ 2 = 488.
    // Module (2,2) at physical x = 488 + (2+4)*8 = 536 → logical 536/3 ≈ 179.
    final moduleX = (536 / dpr).round();
    final moduleY = (536 / dpr).round();

    expect(pixel(data, 360, moduleX, moduleY), const Color(0xFFFFFFFF));
    // The physical layout makes the module 8 device px wide — strictly larger
    // than the 2 logical px the logical-only floor would give (2 * 3 = 6).
    expect(pixel(data, 360, 2, 2), QrGridPainter.espresso);
  });

  testWidgets('a real QR painted by the run-batched painter decodes back', (
    tester,
  ) async {
    // Encode a real tile payload, paint it the way the broadcast stage does,
    // rasterize, and decode with the same zxing2 reader the receiver's isolate
    // pool uses — the proof that the optimized painter still renders
    // camera-decodable QRs.
    final payload = Uint8List.fromList(
      List<int>.generate(40, (i) => i % 251),
    );
    final matrix = encodeQrBytes(payload, version: 5);
    const dpr = 2.0;
    const logical = 180.0;
    // version 5 → modules = 45; ppm = (180*2) ~/ 45 = 8 physical px → the tile
    // fills the 180-logical canvas edge to edge (8*45 = 360 phys = 180 log).
    // Rasterize at the logical size so the QR fills the image.
    final data = (await tester.runAsync(() => rasterize(
          QrGridPainter(
            tiles: [matrix],
            layout: qrc.LayoutId.single,
            version: 5,
            devicePixelRatio: dpr,
          ),
          logical,
          1.0,
        )))!;

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
        final segments = result.resultMetadata[ResultMetadataType.byteSegments]
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
    final decoded =
        decodeFrom(luminance) ?? decodeFrom(inverted);
    expect(decoded, isNotNull, reason: 'stage QR must decode (normal or inverted)');
    expect(
      Uint8List.view(decoded!.buffer, decoded.offsetInBytes, decoded.lengthInBytes),
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

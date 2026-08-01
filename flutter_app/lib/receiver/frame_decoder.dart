/// Frame decoder for the receive flow — turns one camera frame into decoded
/// QR payloads. The production implementation is native ML Kit barcode
/// scanning ([MlKitFrameDecoder]); tests inject a fake.
library;

import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:qr_transfer_core/receiver/decode_pool.dart';

/// One camera frame's QR payloads. [DecodeResult] is core's type, so the
/// rest of the receive pipeline is unchanged.
abstract class FrameDecoder {
  /// Decodes every QR visible in [image] (a YUV420 CameraImage). [rotationDegrees]
  /// is the camera sensor orientation (0/90/180/270) ML Kit uses to correct
  /// the frame for portrait capture.
  Future<List<DecodeResult>> decode(
    CameraImage image, {
    required int rotationDegrees,
  });

  /// Releases native resources. Idempotent.
  void dispose();
}

/// Native ML Kit barcode scanner (bundled model — works offline).
///
/// ML Kit is dramatically more robust than pure-Dart zxing2 (rotation, low
/// light, blur, perspective) and it consumes the raw YUV planes directly —
/// the only work on the UI thread is a memcpy that concatenates the planes,
/// so the per-frame YUV→RGB conversion is gone entirely.
class MlKitFrameDecoder implements FrameDecoder {
  MlKitFrameDecoder() : _scanner = BarcodeScanner();

  final BarcodeScanner _scanner;

  @override
  Future<List<DecodeResult>> decode(
    CameraImage image, {
    required int rotationDegrees,
  }) async {
    final planes = image.planes;
    if (planes.isEmpty) return const [];
    // The camera plugin is configured for NV21, so it delivers ONE tight
    // plane (Y + interleaved VU, no row padding) — the layout ML Kit's
    // InputImage.fromBytes accepts. Other layouts are converted defensively.
    final (Uint8List bytes, int bytesPerRow) =
        planes.length == 1
            ? (planes[0].bytes, image.width)
            : (_toNv21(image), image.width);
    final input = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotationFor(rotationDegrees),
        format: InputImageFormat.nv21,
        bytesPerRow: bytesPerRow,
      ),
    );
    final barcodes = await _scanner.processImage(input);
    return [
      for (final barcode in barcodes)
        if (barcode.rawBytes != null) DecodeResult(bytes: barcode.rawBytes),
    ];
  }

  /// Converts multi-plane YUV420 (with row/column strides) to a tight NV21
  /// buffer — Y plane followed by interleaved VU, the Android standard.
  static Uint8List _toNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final y = image.planes[0];
    final u = image.planes[1];
    final v = image.planes[2];
    final ySize = width * height;
    final out = Uint8List(ySize + ySize ~/ 2);
    for (var row = 0; row < height; row++) {
      out.setRange(row * width, (row + 1) * width, y.bytes, row * y.bytesPerRow);
    }
    final halfW = width ~/ 2;
    final halfH = height ~/ 2;
    final uPix = u.bytesPerPixel ?? 1;
    final vPix = v.bytesPerPixel ?? 1;
    var o = ySize;
    for (var row = 0; row < halfH; row++) {
      final uRow = row * u.bytesPerRow;
      final vRow = row * v.bytesPerRow;
      for (var col = 0; col < halfW; col++) {
        out[o++] = v.bytes[vRow + col * vPix];
        out[o++] = u.bytes[uRow + col * uPix];
      }
    }
    return out;
  }

  @override
  void dispose() {
    _scanner.close();
  }

  static InputImageRotation _rotationFor(int degrees) => switch (degrees) {
    90 => InputImageRotation.rotation90deg,
    180 => InputImageRotation.rotation180deg,
    270 => InputImageRotation.rotation270deg,
    _ => InputImageRotation.rotation0deg,
  };
}

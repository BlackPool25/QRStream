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
    var total = 0;
    for (final plane in planes) {
      total += plane.bytes.length;
    }
    final bytes = Uint8List(total);
    var offset = 0;
    for (final plane in planes) {
      bytes.setRange(offset, offset + plane.bytes.length, plane.bytes);
      offset += plane.bytes.length;
    }
    final input = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotationFor(rotationDegrees),
        format: InputImageFormat.yuv_420_888,
        bytesPerRow: planes[0].bytesPerRow,
      ),
    );
    final barcodes = await _scanner.processImage(input);
    return [
      for (final barcode in barcodes)
        if (barcode.rawBytes != null) DecodeResult(bytes: barcode.rawBytes),
    ];
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

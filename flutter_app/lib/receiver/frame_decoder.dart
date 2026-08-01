/// Frame decoder for the receive flow — turns one camera frame into decoded
/// QR payloads. The production implementation is native ML Kit barcode
/// scanning ([MlKitFrameDecoder]); tests inject a fake.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';
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
    // InputImage.fromBytes accepts. Other layouts are converted with the
    // plugin's own unpackPlane semantics so the output is byte-identical to
    // what the plugin would have produced.
    final (Uint8List bytes, int bytesPerRow) =
        planes.length == 1
            ? (planes[0].bytes, planes[0].bytesPerRow)
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
    try {
      final barcodes = await _scanner.processImage(input);
      return [
        for (final barcode in barcodes)
          if (barcode.rawBytes != null) DecodeResult(bytes: barcode.rawBytes),
      ];
    } on PlatformException catch (e) {
      // Surface the frame layout so a failing device pinpoints the path:
      // single-plane NV21 (camera_android's own conversion) vs the 3-plane
      // fallback, with dims/strides/byte lengths.
      final layout =
          'planes=${planes.length} fmt=${image.format.raw} '
          '${image.width}x${image.height} '
          'bytes=${planes.map((p) => p.bytes.length).toList()} '
          'strides=${planes.map((p) => p.bytesPerRow).toList()} '
          'pix=${planes.map((p) => p.bytesPerPixel).toList()}';
      throw PlatformException(
        code: e.code,
        message: '${e.message} [${e.details}] frame=$layout',
      );
    }
  }

  /// Converts multi-plane YUV420 to a tight NV21 buffer using the camera
  /// plugin's own `unpackPlane` semantics (row stride + pixel stride aware,
  /// with the plane's actual row count derived from its byte length) — the
  /// output is byte-identical to what the plugin's native NV21 conversion
  /// produces, which ML Kit accepts.
  static Uint8List _toNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final ySize = width * height;
    final out = Uint8List(ySize + ySize ~/ 2);
    _unpackPlane(image.planes[0], width, height, out, 0, 1);
    // NV21 interleaves V and U: V at even offsets, U at odd.
    _unpackPlane(image.planes[2], width, height, out, ySize, 2);
    _unpackPlane(image.planes[1], width, height, out, ySize + 1, 2);
    return out;
  }

  static void _unpackPlane(
    Plane plane,
    int width,
    int height,
    Uint8List out,
    int offset,
    int pixelStride,
  ) {
    final bytes = plane.bytes;
    final rowStride = plane.bytesPerRow;
    if (rowStride <= 0 || bytes.isEmpty) return;
    final numRow = (bytes.length + rowStride - 1) ~/ rowStride;
    if (numRow == 0) return;
    final scaleFactor = height ~/ numRow;
    if (scaleFactor == 0) return;
    final numCol = width ~/ scaleFactor;
    final sampleStride = plane.bytesPerPixel ?? 1;
    var outputPos = offset;
    var rowStart = 0;
    for (var row = 0; row < numRow; row++) {
      var inputPos = rowStart;
      for (var col = 0; col < numCol; col++) {
        if (inputPos < bytes.length && outputPos < out.length) {
          out[outputPos] = bytes[inputPos];
        }
        outputPos += pixelStride;
        inputPos += sampleStride;
      }
      rowStart += rowStride;
    }
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

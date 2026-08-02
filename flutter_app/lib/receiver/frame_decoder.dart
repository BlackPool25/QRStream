/// Frame decoder for the receive flow — turns one camera frame into decoded
/// QR payloads. The production implementation is native ML Kit barcode
/// scanning ([MlKitFrameDecoder]); tests inject a fake.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

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
  MlKitFrameDecoder({BarcodeScanner? scanner, DecodePool? zxing})
    : this._(scanner ?? BarcodeScanner(), zxing);

  MlKitFrameDecoder._(this._scanner, this._zxing);

  final BarcodeScanner _scanner;

  /// Last-resort zxing2 decode pool, created lazily — healthy devices never
  /// spawn its isolates.
  DecodePool? _zxing;

  @override
  Future<List<DecodeResult>> decode(
    CameraImage image, {
    required int rotationDegrees,
  }) async {
    final planes = image.planes;
    if (planes.isEmpty) return const [];
    final rotation = _rotationFor(rotationDegrees);
    final size = Size(image.width.toDouble(), image.height.toDouble());

    // Try the layouts in order; ML Kit's native converter has device-specific
    // quirks (some devices reject even byte-perfect NV21 with an NPE), so the
    // first layout the device accepts wins.
    final attempts = buildAttempts(image);

    for (final attempt in attempts) {
      try {
        final barcodes = await _processBytes(
          attempt.bytes,
          attempt.format,
          size,
          rotation,
          image.width,
        );
        return barcodes;
      } on PlatformException {
        // Try the next layout.
      }
    }
    // The byte-array converter is broken on some devices (flutter-ml #628:
    // even byte-perfect NV21 NPEs). The most reliable ML Kit input is a
    // decoded file, so encode the frame to a PNG and fall back to
    // InputImage.fromFilePath — slower, but it works everywhere.
    try {
      final fileInput = await _filePathInput(image, size, rotation);
      try {
        return await _processInput(fileInput);
      } finally {
        // The fallback fires per frame on a broken device — never leave
        // the temp PNG behind.
        final path = fileInput.filePath;
        if (path != null) {
          File(path).delete().catchError((_) => File(path));
        }
      }
    } on PlatformException {
      // ML Kit is entirely broken on this device — fall back to the
      // pure-Dart zxing2 decode pool so scanning still works.
    }
    return _decodeWithZxing(image);
  }

  /// Last-resort decode: core's isolate-backed zxing2 pool on the RGB frame.
  /// The pool is created lazily (spawning isolates per device, not per frame)
  /// and returns an empty list — never an error — when no QR is in view.
  Future<List<DecodeResult>> _decodeWithZxing(CameraImage image) {
    return (_zxing ??= DecodePool()).decode(
      cameraImageToRgb(image),
      image.width,
      image.height,
    );
  }

  /// Converts the frame to raw RGB (3 bytes/pixel, row-major) for the zxing2
  /// decode pool.
  @visibleForTesting
  static Uint8List cameraImageToRgb(CameraImage image) {
    final rgba = _nv21ToRgba(image);
    final rgb = Uint8List(rgba.length * 3 ~/ 4);
    for (var p = 0, o = 0; p < rgba.length; p += 4, o += 3) {
      rgb[o] = rgba[p];
      rgb[o + 1] = rgba[p + 1];
      rgb[o + 2] = rgba[p + 2];
    }
    return rgb;
  }

  /// Builds the byte-format attempts for ML Kit in the order a device should
  /// try them: tight NV21 first, then planar YV12. The yuv_420_888 attempt is
  /// dead — ML Kit's byte-array constructor only accepts NV21 (17) and YV12
  /// (842094169) and throws for anything else. The buffers are laid out as
  /// I420, but the chroma plane order is irrelevant to luma-based QR
  /// detection, so they're passed through as YV12.
  @visibleForTesting
  static List<({InputImageFormat format, Uint8List bytes})> buildAttempts(
    CameraImage image,
  ) {
    final planes = image.planes;
    return [
      if (planes.length == 1) ...[
        // camera_android's own NV21 conversion: one tight plane.
        (format: InputImageFormat.nv21, bytes: planes[0].bytes),
        // YV12 derived from that NV21 plane.
        (
          format: InputImageFormat.yv12,
          bytes: nv21ToI420ForTest(planes[0].bytes, image.width, image.height),
        ),
      ] else ...[
        // Replicate the plugin's conversion semantics byte-for-byte.
        (format: InputImageFormat.nv21, bytes: _toNv21(image)),
        // Tightly-packed planar YV12 (padding stripped from each plane).
        (format: InputImageFormat.yv12, bytes: _toI420(image)),
      ],
    ];
  }

  Future<List<DecodeResult>> _processBytes(
    Uint8List bytes,
    InputImageFormat format,
    Size size,
    InputImageRotation rotation,
    int bytesPerRow,
  ) async {
    final input = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: size,
        rotation: rotation,
        format: format,
        bytesPerRow: bytesPerRow,
      ),
    );
    return _processInput(input);
  }

  Future<List<DecodeResult>> _processInput(InputImage input) async {
    final barcodes = await _scanner.processImage(input);
    return [
      for (final barcode in barcodes)
        if (barcode.rawBytes != null) DecodeResult(bytes: barcode.rawBytes),
    ];
  }

  /// Encodes the frame to a PNG file and builds the ML Kit input from it.
  Future<InputImage> _filePathInput(
    CameraImage image,
    Size size,
    InputImageRotation rotation,
  ) async {
    final rgba = _nv21ToRgba(image);
    final imageObj = await _decodeRgba(rgba, image.width, image.height);
    final png = await imageObj.toByteData(format: ui.ImageByteFormat.png);
    imageObj.dispose();
    final file = File(
      '${Directory.systemTemp.path}/qr_frame_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(png!.buffer.asUint8List(), flush: true);
    return InputImage.fromFilePath(file.path);
  }

  static Future<ui.Image> _decodeRgba(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  /// Converts the single-plane NV21 (or 3-plane YUV) frame to RGBA.
  static Uint8List _nv21ToRgba(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final out = Uint8List(width * height * 4);
    if (image.planes.length == 1) {
      final nv21 = image.planes[0].bytes;
      final ySize = width * height;
      for (var p = 0; p < ySize; p++) {
        final y = nv21[p];
        final chroma = ySize + (p ~/ width ~/ 2) * width + (p % width ~/ 2) * 2;
        final v = nv21[chroma];
        final u = nv21[chroma + 1];
        _writeRgb(out, p, y, u, v);
      }
    } else {
      // 3-plane YUV: use the plugin-style stride handling.
      final y = image.planes[0];
      final u = image.planes[1];
      final v = image.planes[2];
      for (var row = 0; row < height; row++) {
        for (var col = 0; col < width; col++) {
          final yy = y.bytes[row * y.bytesPerRow + col];
          final uu = u.bytes[row ~/ 2 * u.bytesPerRow + col ~/ 2];
          final vv = v.bytes[row ~/ 2 * v.bytesPerRow + col ~/ 2];
          _writeRgb(out, row * width + col, yy, uu, vv);
        }
      }
    }
    return out;
  }

  /// BT.601 full-range YUV -> RGB, packed as RGBA (alpha 255).
  static void _writeRgb(Uint8List out, int p, int y, int u, int v) {
    final c = y - 16;
    final d = u - 128;
    final e = v - 128;
    final r = (298 * c + 409 * e + 128) >> 8;
    final g = (298 * c - 100 * d - 208 * e + 128) >> 8;
    final b = (298 * c + 516 * d + 128) >> 8;
    final o = p * 4;
    out[o] = r < 0 ? 0 : (r > 255 ? 255 : r);
    out[o + 1] = g < 0 ? 0 : (g > 255 ? 255 : g);
    out[o + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
    out[o + 3] = 0xFF;
  }

  /// Splits a single-plane NV21 buffer into tightly-packed planar I420
  /// (Y + U + V) — the other layout Android ML Kit's converter accepts.
  @visibleForTesting
  static Uint8List nv21ToI420ForTest(Uint8List nv21, int width, int height) {
    final ySize = width * height;
    final out = Uint8List(ySize * 3 ~/ 2);
    out.setRange(0, ySize, nv21, 0);
    var u = ySize;
    var v = ySize + ySize ~/ 4;
    for (var i = ySize; i + 1 < nv21.length; i += 2) {
      out[v++] = nv21[i]; // V at even UV offsets
      out[u++] = nv21[i + 1]; // U at odd UV offsets
    }
    return out;
  }

  /// Tightly-packed planar I420: Y + U + V, row padding stripped.
  static Uint8List _toI420(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final out = Uint8List(width * height * 3 ~/ 2);
    _unpackPlane(image.planes[0], width, height, out, 0, 1);
    _unpackPlane(image.planes[1], width, height, out, width * height, 1);
    _unpackPlane(
      image.planes[2],
      width,
      height,
      out,
      width * height * 5 ~/ 4,
      1,
    );
    return out;
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
    // The null check matters: never create the pool during dispose.
    _zxing?.dispose();
  }

  static InputImageRotation _rotationFor(int degrees) => switch (degrees) {
    90 => InputImageRotation.rotation90deg,
    180 => InputImageRotation.rotation180deg,
    270 => InputImageRotation.rotation270deg,
    _ => InputImageRotation.rotation0deg,
  };
}

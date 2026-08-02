/// Frame decoder for the receive flow — turns one camera frame into decoded
/// QR payloads. The production implementation is native ML Kit barcode
/// scanning ([MlKitFrameDecoder]); tests inject a fake.
///
/// Decode order in [MlKitFrameDecoder.decode]: **ZXing-C++ is primary** — the
/// native FFI decoder runs first over a tight luma frame; when it finds at
/// least one QR its payload is authoritative. On an empty result (no QR this
/// frame) or an FFI failure it degrades to the ML Kit chain (NV21 → YV12 →
/// PNG file), which stays as the robust fallback for low-light/blurred
/// frames; the pure-Dart zxing2 DecodePool is the last resort when ML Kit is
/// broken on the device.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:qr_transfer_core/codec/zxing_cpp_bridge.dart';
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

/// Which input path a [MlKitFrameDecoder.decode] call actually used — the
/// diagnostic that shows where per-frame time goes (and whether ML Kit is
/// healthy on the device at all, or the zxing fallback is carrying the load).
enum MlKitDecodePath { zxingCpp, nv21, yv12, pngFile, zxing }

/// One decode call's outcome: the path used and its wall-clock duration.
class MlKitDecodeTiming {
  MlKitDecodeTiming(this.path, this.duration);

  final MlKitDecodePath path;
  final Duration duration;
}

/// Primary native QR decoder (ZXing-C++) with ML Kit as the robust fallback
/// and pure-Dart zxing2 as the last resort.
///
/// ZXing-C++ runs first on a tight grayscale luma frame — no YUV→RGB
/// conversion, a single synchronous FFI call per frame. When it finds at
/// least one QR the result is authoritative; an empty result or an FFI
/// failure falls through to ML Kit (bundled model — works offline), which
/// is more robust in low light, blur and perspective. zxing2's isolate pool
/// only carries a device where ML Kit is entirely broken.
class MlKitFrameDecoder implements FrameDecoder {
  MlKitFrameDecoder({
    BarcodeScanner? scanner,
    DecodePool? zxing,
    ZxingCppDecode? zxingCpp,
  }) : this._(
         // QR-only: ML Kit decodes every barcode format by default, which is
         // its #1 documented latency cost. This stream only ever carries QR.
         scanner ?? BarcodeScanner(formats: const [BarcodeFormat.qrCode]),
         zxing,
         // Default: the real ZXing-C++ facade. A broken/absent FFI must
         // degrade to ML Kit, never throw, so the wrapper swallows every
         // error and reports "no QR". The closure is created eagerly but the
         // facade's Rust-lib load stays lazy — the default constructor never
         // touches the FFI.
         zxingCpp ??
             (Uint8List luma, int width, int height) {
               try {
                 return decodeLuma(luma, width, height);
               } catch (_) {
                 return const [];
               }
             },
       );

  MlKitFrameDecoder._(this._scanner, this._zxing, this._zxingCpp);

  final BarcodeScanner _scanner;

  /// Diagnostic: path + duration of the most recent [decode] call, surfaced
  /// by the receive view to explain per-frame decode cost.
  MlKitDecodeTiming? get lastTiming => _lastTiming;

  /// The underlying scanner — exposed so tests can assert the default
  /// format restriction.
  @visibleForTesting
  BarcodeScanner get scanner => _scanner;

  MlKitDecodeTiming? _lastTiming;

  /// Last-resort zxing2 decode pool, created lazily — healthy devices never
  /// spawn its isolates.
  DecodePool? _zxing;

  /// Primary decoder: the native ZXing-C++ FFI seam, injected so tests can
  /// fake it. Runs first over the tight luma frame.
  final ZxingCppDecode _zxingCpp;

  @override
  Future<List<DecodeResult>> decode(
    CameraImage image, {
    required int rotationDegrees,
  }) async {
    final stopwatch = Stopwatch()..start();
    final planes = image.planes;
    if (planes.isEmpty) return const [];

    // PRIMARY — ZXing-C++ over the tight luma frame. Synchronous FFI, no
    // YUV→RGB conversion. Its payload is authoritative whenever it finds at
    // least one QR; an empty result or a thrown error falls through to ML
    // Kit (low-light/blurred frames may decode natively when ZXing-C++
    // cannot, and a broken FFI must never take the receive path down).
    try {
      final payloads = _zxingCpp(
        cameraImageToLuma(image),
        image.width,
        image.height,
      );
      if (payloads.isNotEmpty) {
        _lastTiming = MlKitDecodeTiming(
          MlKitDecodePath.zxingCpp,
          stopwatch.elapsed,
        );
        return [for (final payload in payloads) DecodeResult(bytes: payload)];
      }
    } catch (_) {
      // FFI failure — fall through to ML Kit.
    }

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
        _lastTiming = MlKitDecodeTiming(
          _pathFor(attempt.format),
          stopwatch.elapsed,
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
        final barcodes = await _processInput(fileInput);
        _lastTiming = MlKitDecodeTiming(
          MlKitDecodePath.pngFile,
          stopwatch.elapsed,
        );
        return barcodes;
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
    final barcodes = await _decodeWithZxing(image);
    _lastTiming = MlKitDecodeTiming(MlKitDecodePath.zxing, stopwatch.elapsed);
    return barcodes;
  }

  static MlKitDecodePath _pathFor(InputImageFormat format) => switch (format) {
    InputImageFormat.nv21 => MlKitDecodePath.nv21,
    _ => MlKitDecodePath.yv12,
  };

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

  /// Extracts the tight `width * height` grayscale (luma) buffer the native
  /// ZXing-C++ decoder consumes — 1 byte per pixel, row-major, exactly
  /// `width * height` bytes. Mirrors [cameraImageToRgb]: a single-plane frame
  /// (camera_android's tight NV21) contributes its first `width * height`
  /// bytes directly; a 3-plane YUV420 frame contributes the Y plane with
  /// row-stride awareness (padding stripped).
  @visibleForTesting
  static Uint8List cameraImageToLuma(CameraImage image) {
    final out = Uint8List(image.width * image.height);
    if (image.planes.length == 1) {
      final bytes = image.planes[0].bytes;
      out.setRange(0, out.length, bytes, 0);
    } else {
      _unpackPlane(image.planes[0], image.width, image.height, out, 0, 1);
    }
    return out;
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

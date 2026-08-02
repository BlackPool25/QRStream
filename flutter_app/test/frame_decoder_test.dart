// Frame decoder tests — ML Kit attempt-layout selection (nv21 → yv12) and the
// zxing2 DecodePool last-resort fallback when ML Kit is broken on a device.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:qr_data_transfer/receiver/frame_decoder.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/receiver/decode_pool.dart';

/// Single-plane (tight NV21) camera frame, like camera_android delivers.
CameraImage _singlePlaneImage(Uint8List bytes, int width, int height) =>
    CameraImage.fromPlatformInterface(
      CameraImageData(
        format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
        planes: [CameraImagePlane(bytes: bytes, bytesPerRow: width)],
        height: height,
        width: width,
      ),
    );

/// 3-plane YUV420 camera frame with row-padded planes.
CameraImage _threePlaneImage(
  Uint8List y,
  Uint8List u,
  Uint8List v,
  int width,
  int height,
) => CameraImage.fromPlatformInterface(
  CameraImageData(
    format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
    planes: [
      CameraImagePlane(bytes: y, bytesPerRow: width),
      CameraImagePlane(bytes: u, bytesPerRow: width ~/ 2),
      CameraImagePlane(bytes: v, bytesPerRow: width ~/ 2),
    ],
    height: height,
    width: width,
  ),
);

/// Deterministic synthetic DATA wire frame (mirrors core's decode_pool_test).
Uint8List _wireFrame(int seed) {
  final payload = Uint8List.fromList(
    List<int>.generate(128, (i) => (seed * 31 + i * 7) & 0xff),
  );
  return encodeFrame(
    Frame(
      type: typeData,
      sessionId: generateSessionId(),
      esi: seed,
      k: 200,
      totalLen: 0,
      flags: 0,
      payload: payload,
    ),
  );
}

/// Rasterizes [frame] to raw RGB bytes (mirrors core's rgbImage helper).
({Uint8List rgb, int px}) _rgbImage(Uint8List frame) {
  final qr = encodeQrBytes(frame);
  const ppm = 4, quiet = 4;
  final side = qr.size;
  final px = (side + 2 * quiet) * ppm;
  final rgb = Uint8List(px * px * 3);
  for (var y = 0; y < px; y++) {
    for (var x = 0; x < px; x++) {
      final mx = x ~/ ppm - quiet;
      final my = y ~/ ppm - quiet;
      final dark =
          mx >= 0 &&
          mx < side &&
          my >= 0 &&
          my < side &&
          qr.modules[my * side + mx] == 1;
      final offset = (y * px + x) * 3;
      rgb[offset] = dark ? 0 : 255;
      rgb[offset + 1] = dark ? 0 : 255;
      rgb[offset + 2] = dark ? 0 : 255;
    }
  }
  return (rgb: rgb, px: px);
}

/// BarcodeScanner that throws for every input — models a device where ML Kit
/// is entirely broken. close() must be overridden or dispose() hits the
/// MethodChannel and throws MissingPluginException in tests.
class _FailingScanner extends BarcodeScanner {
  @override
  Future<List<Barcode>> processImage(InputImage input) async {
    throw PlatformException(code: 'x');
  }

  @override
  Future<void> close() async {}
}

/// Records the input format of every decode; returns one barcode on the
/// first call, then throws — proves the healthy fast path wins on attempt 1
/// and the zxing pool is never reached.
class _RecordingScanner extends BarcodeScanner {
  final inputFormats = <InputImageFormat>[];
  int calls = 0;

  @override
  Future<List<Barcode>> processImage(InputImage input) async {
    calls++;
    inputFormats.add(input.metadata!.format);
    if (calls == 1) {
      return [
        Barcode(
          type: BarcodeType.unknown,
          format: BarcodeFormat.qrCode,
          displayValue: null,
          rawValue: null,
          rawBytes: Uint8List.fromList(<int>[1, 2, 3]),
          boundingBox: Rect.zero,
          cornerPoints: const [],
          value: null,
        ),
      ];
    }
    throw PlatformException(code: 'x');
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('nv21ToI420 produces the correct planar layout', () {
    // 4x4 frame: Y = 0..15, UV interleaved (V at even, U at odd).
    const w = 4, h = 4;
    final nv21 = Uint8List(w * h * 3 ~/ 2);
    for (var i = 0; i < w * h; i++) {
      nv21[i] = (100 + i) & 0xff; // Y
    }
    final uv = w * h;
    for (var i = 0; i < w * h ~/ 4; i++) {
      nv21[uv + 2 * i] = (200 + i) & 0xff; // V
      nv21[uv + 2 * i + 1] = (10 + i) & 0xff; // U
    }

    final i420 = MlKitFrameDecoder.nv21ToI420ForTest(nv21, w, h);
    // Y plane unchanged.
    for (var i = 0; i < w * h; i++) {
      expect(i420[i], (100 + i) & 0xff);
    }
    // U plane at offset w*h, V plane after it.
    for (var i = 0; i < w * h ~/ 4; i++) {
      expect(i420[w * h + i], (10 + i) & 0xff, reason: 'U plane');
      expect(i420[w * h + w * h ~/ 4 + i], (200 + i) & 0xff, reason: 'V plane');
    }
  });

  group('buildAttempts', () {
    test(
      'single-plane NV21 offers nv21 then yv12, first is the plane bytes',
      () {
        const w = 4, h = 4;
        final nv21 = Uint8List(w * h * 3 ~/ 2);
        for (var i = 0; i < w * h; i++) {
          nv21[i] = (100 + i) & 0xff;
        }
        nv21.fillRange(w * h, nv21.length, 128);
        final image = _singlePlaneImage(nv21, w, h);

        final attempts = MlKitFrameDecoder.buildAttempts(image);

        expect(attempts.map((a) => a.format).toList(), [
          InputImageFormat.nv21,
          InputImageFormat.yv12,
        ]);
        expect(identical(attempts[0].bytes, image.planes[0].bytes), isTrue);
      },
    );

    test('3-plane YUV420 offers nv21 then yv12 with a tight planar buffer', () {
      const w = 4, h = 4;
      final y = Uint8List(w * h)..fillRange(0, w * h, 100);
      final u = Uint8List(w * h ~/ 4)..fillRange(0, w * h ~/ 4, 128);
      final v = Uint8List(w * h ~/ 4)..fillRange(0, w * h ~/ 4, 128);
      final image = _threePlaneImage(y, u, v, w, h);

      final attempts = MlKitFrameDecoder.buildAttempts(image);

      expect(attempts.map((a) => a.format).toList(), [
        InputImageFormat.nv21,
        InputImageFormat.yv12,
      ]);
      expect(attempts[1].bytes.length, w * h * 3 ~/ 2);
    });
  });

  group('cameraImageToRgb', () {
    test('4x4 NV21 → RGB, BT.601 luma, no chroma bleed', () {
      const w = 4, h = 4;
      final nv21 = Uint8List(w * h * 3 ~/ 2);
      for (var i = 0; i < w * h; i++) {
        nv21[i] = 100; // Y
      }
      nv21.fillRange(w * h, nv21.length, 128); // U = V = 128 → gray
      final image = _singlePlaneImage(nv21, w, h);

      final rgb = MlKitFrameDecoder.cameraImageToRgb(image);

      expect(rgb.length, w * h * 3);
      for (var p = 0; p < w * h; p++) {
        expect(rgb[p * 3], rgb[p * 3 + 1], reason: 'gray pixel $p: r == g');
        expect(rgb[p * 3 + 1], rgb[p * 3 + 2], reason: 'gray pixel $p: g == b');
      }
      // BT.601: c = 100 - 16 = 84 → (298 * 84 + 128) >> 8 ≈ 98.
      expect(rgb[0], closeTo(98, 3));
    });

    test('3-plane image yields width * height * 3 bytes', () {
      const w = 4, h = 4;
      final y = Uint8List(w * h)..fillRange(0, w * h, 100);
      final u = Uint8List(w * h ~/ 4)..fillRange(0, w * h ~/ 4, 128);
      final v = Uint8List(w * h ~/ 4)..fillRange(0, w * h ~/ 4, 128);
      final image = _threePlaneImage(y, u, v, w, h);

      final rgb = MlKitFrameDecoder.cameraImageToRgb(image);

      expect(rgb.length, w * h * 3);
    });
  });

  group('cameraImageToLuma', () {
    test('single-plane NV21 → tight width*height grayscale buffer', () {
      const w = 4, h = 4;
      final nv21 = Uint8List(w * h * 3 ~/ 2);
      for (var i = 0; i < w * h; i++) {
        nv21[i] = (10 + i) & 0xff; // distinct Y values
      }
      nv21.fillRange(w * h, nv21.length, 128); // chroma
      final image = _singlePlaneImage(nv21, w, h);

      final luma = MlKitFrameDecoder.cameraImageToLuma(image);

      expect(luma.length, w * h);
      for (var i = 0; i < w * h; i++) {
        expect(luma[i], (10 + i) & 0xff, reason: 'luma pixel $i');
      }
    });

    test('3-plane YUV420 → tight width*height Y plane, row-stride aware', () {
      const w = 8, h = 6, stride = w + 2;
      // Row-padded Y plane: `stride` bytes per row, 2 padding bytes each.
      final y = Uint8List(stride * h);
      for (var row = 0; row < h; row++) {
        for (var col = 0; col < w; col++) {
          y[row * stride + col] = (row * w + col) & 0xff;
        }
        y[row * stride + w] = 0xEE;
        y[row * stride + w + 1] = 0xEE;
      }
      final u = Uint8List(w * h ~/ 4)..fillRange(0, w * h ~/ 4, 128);
      final v = Uint8List(w * h ~/ 4)..fillRange(0, w * h ~/ 4, 128);
      final image = CameraImage.fromPlatformInterface(
        CameraImageData(
          format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
          planes: [
            CameraImagePlane(bytes: y, bytesPerRow: stride),
            CameraImagePlane(bytes: u, bytesPerRow: w ~/ 2),
            CameraImagePlane(bytes: v, bytesPerRow: w ~/ 2),
          ],
          height: h,
          width: w,
        ),
      );

      final luma = MlKitFrameDecoder.cameraImageToLuma(image);

      expect(luma.length, w * h);
      // Spot-check every pixel: tight row-major, padding stripped.
      for (var row = 0; row < h; row++) {
        for (var col = 0; col < w; col++) {
          expect(
            luma[row * w + col],
            y[row * stride + col],
            reason: 'row $row col $col',
          );
        }
      }
    });
  });

  test(
    'ML Kit broken on the device → zxing DecodePool decodes byte-exact',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final frame = _wireFrame(0);
      final image = _rgbImage(frame);
      // Tight single-plane NV21: Y = BT.601 luma of the pixel, U = V = 128.
      final nv21 = Uint8List(image.px * image.px * 3 ~/ 2);
      for (var p = 0; p < image.px * image.px; p++) {
        nv21[p] =
            (77 * image.rgb[p * 3] +
                150 * image.rgb[p * 3 + 1] +
                29 * image.rgb[p * 3 + 2]) >>
            8;
      }
      nv21.fillRange(image.px * image.px, nv21.length, 128);
      final img = _singlePlaneImage(nv21, image.px, image.px);

      final decoder = MlKitFrameDecoder(
        scanner: _FailingScanner(),
        zxing: DecodePool(),
        // zxing-cpp must not intercept this frame — the test exercises the
        // zxing2-pool last resort.
        zxingCpp: (_, _, _) => const [],
      );
      final results = await decoder.decode(img, rotationDegrees: 0);
      decoder.dispose();

      expect(results, hasLength(1));
      expect(results.single.bytes, equals(frame));
      expect(decoder.lastTiming?.path, MlKitDecodePath.zxing);
    },
  );

  test('healthy ML Kit wins on nv21, the zxing pool is never hit', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const w = 4, h = 4;
    final nv21 = Uint8List(w * h * 3 ~/ 2);
    for (var i = 0; i < w * h; i++) {
      nv21[i] = 100;
    }
    nv21.fillRange(w * h, nv21.length, 128);
    final image = _singlePlaneImage(nv21, w, h);
    final scanner = _RecordingScanner();
    final decoder = MlKitFrameDecoder(
      scanner: scanner,
      // zxing-cpp finds nothing this frame — the healthy ML Kit nv21 path is
      // the one under test.
      zxingCpp: (_, _, _) => const [],
    );

    final results = await decoder.decode(image, rotationDegrees: 0);

    expect(results, hasLength(1));
    expect(results.single.bytes, <int>[1, 2, 3]);
    expect(scanner.calls, 1);
    expect(scanner.inputFormats.first, InputImageFormat.nv21);
    expect(decoder.lastTiming?.path, MlKitDecodePath.nv21);
  });

  test('zxingCpp primary path decodes byte-exact via injected fake', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final frame = _wireFrame(0);
    final image = _rgbImage(frame);
    // Tight single-plane NV21: Y = BT.601 luma of the pixel, U = V = 128.
    final nv21 = Uint8List(image.px * image.px * 3 ~/ 2);
    for (var p = 0; p < image.px * image.px; p++) {
      nv21[p] =
          (77 * image.rgb[p * 3] +
              150 * image.rgb[p * 3 + 1] +
              29 * image.rgb[p * 3 + 2]) >>
          8;
    }
    nv21.fillRange(image.px * image.px, nv21.length, 128);
    final img = _singlePlaneImage(nv21, image.px, image.px);

    final scanner = _RecordingScanner();
    final decoder = MlKitFrameDecoder(
      scanner: scanner,
      zxingCpp: (luma, w, h) => [frame],
    );
    final results = await decoder.decode(img, rotationDegrees: 0);
    decoder.dispose();

    expect(results, hasLength(1));
    expect(results.single.bytes, equals(frame));
    expect(decoder.lastTiming?.path, MlKitDecodePath.zxingCpp);
    expect(
      scanner.calls,
      0,
      reason: 'ML Kit must never run when zxing-cpp decodes',
    );
  });

  test('zxingCpp empty → ML Kit nv21 wins', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const w = 4, h = 4;
    final nv21 = Uint8List(w * h * 3 ~/ 2);
    for (var i = 0; i < w * h; i++) {
      nv21[i] = 100;
    }
    nv21.fillRange(w * h, nv21.length, 128);
    final image = _singlePlaneImage(nv21, w, h);
    final scanner = _RecordingScanner();
    final decoder = MlKitFrameDecoder(
      scanner: scanner,
      zxingCpp: (_, _, _) => const [],
    );

    final results = await decoder.decode(image, rotationDegrees: 0);

    expect(results, hasLength(1));
    expect(results.single.bytes, <int>[1, 2, 3]);
    expect(scanner.calls, 1);
    expect(scanner.inputFormats.first, InputImageFormat.nv21);
    expect(decoder.lastTiming?.path, MlKitDecodePath.nv21);
  });

  test('zxingCpp throws → ML Kit nv21 still handles', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const w = 4, h = 4;
    final nv21 = Uint8List(w * h * 3 ~/ 2);
    for (var i = 0; i < w * h; i++) {
      nv21[i] = 100;
    }
    nv21.fillRange(w * h, nv21.length, 128);
    final image = _singlePlaneImage(nv21, w, h);
    final scanner = _RecordingScanner();
    final decoder = MlKitFrameDecoder(
      scanner: scanner,
      zxingCpp: (_, _, _) => throw StateError('ffi down'),
    );

    final results = await decoder.decode(image, rotationDegrees: 0);

    expect(results, hasLength(1));
    expect(results.single.bytes, <int>[1, 2, 3]);
    expect(scanner.calls, 1);
    expect(decoder.lastTiming?.path, MlKitDecodePath.nv21);
  });

  test('default decoder restricts ML Kit to QR_CODE only (faster decode)', () {
    final decoder = MlKitFrameDecoder();
    expect(decoder.scanner.formats, [BarcodeFormat.qrCode]);
  });
}

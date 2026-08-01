// NV21 <-> I420 layout conversions used to feed ML Kit's InputImage.fromBytes.
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_data_transfer/receiver/frame_decoder.dart';

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
}

/// Camera abstraction for the receive view (Wave 5 T5.5).
///
/// A [CameraService] is a frame source that delivers RGB pixels to a
/// consumer. The receive view depends on this abstraction only, so tests can
/// inject a fake that yields synthetic frames (QR images rasterized from the
/// committed fixtures) while the real Android app runs
/// [PluginCameraService] over the `camera` plugin. Linux is send-only and
/// never constructs a service.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

/// One RGB camera frame: `width * height * 3` bytes, row-major.
typedef FrameConsumer = void Function(Uint8List rgb, int width, int height);

/// Contract the receive view drives. Implementations must be safe to
/// [start] once; [stop] is idempotent and always safe to call.
abstract class CameraService {
  /// Begins delivering frames to [onFrame]. Frames may start arriving before
  /// this future resolves. Throws on camera acquisition failure.
  Future<void> start(FrameConsumer onFrame);

  /// Stops frame delivery. Safe to call when not started.
  Future<void> stop();
}

/// Real camera: wraps the `camera` plugin's [CameraController] and converts
/// the YUV image stream to tight RGB before forwarding each frame. The
/// controller is created on first [start] from the first available camera.
///
/// The CAMERA permission is requested EXPLICITLY before the plugin is touched:
/// CameraX's `availableCameras()` can return empty / throw when the permission
/// is not yet granted, and the plugin's own request (inside `initialize()`)
/// races its permission callback. A pre-granted permission makes the plugin's
/// internal request a no-op success.
class PluginCameraService implements CameraService {
  /// [controller] may be supplied (tests / embedders); otherwise the service
  /// acquires the first available camera itself.
  // The public parameter cannot be an initializing formal for the private
  // `_controller` field (a private-named named-parameter is not callable
  // from outside the library).
  // ignore: prefer_initializing_formals
  PluginCameraService({CameraController? controller}) : _controller = controller;

  CameraController? _controller;
  FrameConsumer? _consumer;
  bool _started = false;

  @override
  Future<void> start(FrameConsumer onFrame) async {
    _consumer = onFrame;
    if (_started) {
      return;
    }
    if (Platform.isAndroid) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        throw CameraException(
          'CameraAccessDenied',
          'Camera permission was denied — enable it in the app settings.',
        );
      }
    }
    var controller = _controller;
    if (controller == null) {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('No camera found on this device', 'camera');
      }
      controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      _controller = controller;
    }
    await controller.startImageStream(_onImage);
    _started = true;
  }

  void _onImage(CameraImage image) {
    final consumer = _consumer;
    if (consumer == null) {
      return;
    }
    consumer(_yuv420ToRgb(image), image.width, image.height);
  }

  @override
  Future<void> stop() async {
    _consumer = null;
    final controller = _controller;
    if (controller != null && _started) {
      await controller.stopImageStream();
    }
    _started = false;
  }
}

/// Converts a YUV420 [CameraImage] (planes Y/U/V with per-plane row stride)
/// to tight `width * height * 3` RGB bytes using the BT.601 full-range
/// coefficients. Handles the common Android yuv420 layouts.
Uint8List _yuv420ToRgb(CameraImage image) {
  final planes = image.planes;
  final yPlane = planes[0];
  final uPlane = planes[1];
  final vPlane = planes[2];
  final width = image.width;
  final height = image.height;
  final out = Uint8List(width * height * 3);
  var o = 0;
  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      final y = yPlane.bytes[row * yPlane.bytesPerRow + col];
      final u = uPlane.bytes[(row >> 1) * uPlane.bytesPerRow + (col >> 1)];
      final v = vPlane.bytes[(row >> 1) * vPlane.bytesPerRow + (col >> 1)];
      final c = y - 16;
      final d = u - 128;
      final e = v - 128;
      final r = (298 * c + 409 * e + 128) >> 8;
      final g = (298 * c - 100 * d - 208 * e + 128) >> 8;
      final b = (298 * c + 516 * d + 128) >> 8;
      out[o++] = r < 0 ? 0 : (r > 255 ? 255 : r);
      out[o++] = g < 0 ? 0 : (g > 255 ? 255 : g);
      out[o++] = b < 0 ? 0 : (b > 255 ? 255 : b);
    }
  }
  return out;
}

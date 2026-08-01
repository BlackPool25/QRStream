/// Camera abstraction for the receive view (Wave 5 T5.5).
///
/// A [CameraService] is a frame source that delivers camera frames to a
/// consumer. The receive view depends on this abstraction only, so tests can
/// inject a fake that yields synthetic frames while the real Android app runs
/// [PluginCameraService] over the `camera` plugin. Linux is send-only and
/// never constructs a service.
///
/// Frames are delivered as the raw [CameraImage] plus the sensor rotation
/// degrees — the ML Kit decoder consumes the YUV planes directly, so no
/// per-frame pixel conversion happens on the UI thread.
library;

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

/// One camera frame: the raw YUV image plus the sensor orientation (0/90/180/270)
/// the decoder needs to correct the frame for portrait capture.
typedef FrameConsumer = void Function(CameraImage image, int rotationDegrees);

/// Contract the receive view drives. Implementations must be safe to
/// [start] once; [stop] is idempotent and always safe to call.
abstract class CameraService {
  /// Begins delivering frames to [onFrame]. Frames may start arriving before
  /// this future resolves. Throws on camera acquisition failure.
  Future<void> start(FrameConsumer onFrame);

  /// Stops frame delivery. Safe to call when not started.
  Future<void> stop();

  /// Optional live camera preview widget to show while scanning; null when
  /// the service has no previewable controller (fakes, Linux).
  Widget? buildPreview() => null;

  /// Switches between the front and back cameras. No-op when unsupported.
  Future<void> flipCamera() async {}

  /// Toggles the torch (flashlight). No-op when unsupported.
  Future<void> setTorch(bool enabled) async {}

  /// Sets the zoom factor (1.0 = none). No-op when unsupported.
  Future<void> setZoom(double zoom) async {}
}

/// Real camera: wraps the `camera` plugin's [CameraController] and delivers
/// each frame's raw [CameraImage] plus its sensor rotation. The controller is
/// created on first [start] from the first available (back) camera.
///
/// The CAMERA permission is requested EXPLICITLY before the plugin is touched:
/// Camera2's `availableCameras()` can fail when the permission is not yet
/// granted, and the plugin's own request races its callback. A pre-granted
/// permission makes the plugin's internal request a no-op success.
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
  int _sensorOrientation = 90;
  Stopwatch? _frameClock;

  /// Minimum interval between frames handed to the consumer — the camera
  /// streams at ~30 fps, but dispatching decodes at that rate overwhelms
  /// mid-range phones (the PWA showed the same discipline: a controlled
  /// capture cadence). ~66 ms caps processing at ~15 fps, which the decoder
  /// keeps up with easily.
  static const Duration _frameInterval = Duration(milliseconds: 66);

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
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _sensorOrientation = back.sensorOrientation;
      controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        // The plugin converts the YUV frames to a single tightly-packed NV21
        // plane (no row padding) — exactly the layout Android ML Kit's
        // InputImage.fromBytes expects.
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      // Continuous autofocus — critical for sharp QR modules at close range.
      // Best-effort: not every device/plugin supports every mode.
      try {
        await controller.setFocusMode(FocusMode.auto);
      } on CameraException {
        // ignore: unsupported focus mode
      }
      _controller = controller;
    }
    await controller.startImageStream(_onImage);
    _started = true;
  }

  /// Throttled frame dispatch: drops frames that arrive within
  /// [_frameInterval] of the last processed one.
  void _onImage(CameraImage image) {
    final consumer = _consumer;
    if (consumer == null) return;
    final clock = _frameClock ??= Stopwatch()..start();
    if (clock.elapsedMilliseconds < _frameInterval.inMilliseconds) return;
    clock.reset();
    consumer(image, _sensorOrientation);
  }

  @override
  Future<void> flipCamera() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final cameras = await availableCameras();
      final current = controller.description.lensDirection;
      final next = cameras.firstWhere(
        (c) => c.lensDirection != current,
        orElse: () => cameras.first,
      );
      await controller.setDescription(next);
      _sensorOrientation = next.sensorOrientation;
    } on CameraException {
      // ignore: unsupported camera switch
    }
  }

  @override
  Future<void> setTorch(bool enabled) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setFlashMode(enabled ? FlashMode.torch : FlashMode.off);
    } on CameraException {
      // ignore: unsupported torch
    }
  }

  @override
  Future<void> setZoom(double zoom) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final maxZoom = await controller.getMaxZoomLevel();
      final minZoom = await controller.getMinZoomLevel();
      await controller.setZoomLevel(zoom.clamp(minZoom, maxZoom));
    } on CameraException {
      // ignore: unsupported zoom
    }
  }

  /// The live camera preview once [start] has initialized the controller.
  @override
  Widget? buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    return CameraPreview(controller);
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

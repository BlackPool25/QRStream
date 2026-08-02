// Receive view widget tests (Wave 5 T5.5) — the full receive flow on the REAL
// pipeline: a FakeCameraService yields the committed PWA fixtures (read from
// ../core/test/fixtures) rasterized to QR images, the real DecodePool decodes
// them, and the real FrameBuffer + real Rust-backed Reassembler reassemble the
// file. The injected fake saver records the bytes it was handed.
//
// This mirrors the PWA's virtual-camera e2e: the reassembled file must be
// byte-identical to the fixture's original.bin, the VERIFIED (SHA-256) badge
// must appear before the Save card, and tapping Open must reach the saver's
// open path. The Rust dylib is resolved like the broadcast-controller test
// (flutter_app/rust/target/debug), and the DecodePool is created in setUpAll
// (real async) so its isolates are ready for the fake-async test body.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:qr_data_transfer/receiver/camera_service.dart';
import 'package:qr_data_transfer/receiver/frame_decoder.dart';
import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_data_transfer/ui/receive_view.dart';
import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/receiver/decode_pool.dart' show DecodeResult;

/// A committed PWA fixture set (wire frames + original bytes).
class Fixture {
  Fixture(this.name) {
    final dir = 'core/test/fixtures/$name';
    metaFrame = File('$dir/meta.frame').readAsBytesSync();
    dataFrames = _splitLengthPrefixed(
      File('$dir/data.frames').readAsBytesSync(),
    );
    original = File('$dir/original.bin').readAsBytesSync();
  }

  final String name;
  late final Uint8List metaFrame;
  late final List<Uint8List> dataFrames;
  late final Uint8List original;
}

/// Splits a [u32BE len][frame bytes]… stream (the fixture on-disk format).
List<Uint8List> _splitLengthPrefixed(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final out = <Uint8List>[];
  var off = 0;
  while (off < bytes.length) {
    final len = view.getUint32(off, Endian.big);
    off += 4;
    out.add(Uint8List.sublistView(bytes, off, off + len));
    off += len;
  }
  return out;
}

/// Camera fake: delivers [frameCount] minimal CameraImages on start, exactly
/// like the plugin delivering frames to the (injected) frame decoder.
class FakeCameraService implements CameraService {
  FakeCameraService(this.frameCount, {this.preview});

  final int frameCount;

  /// Optional fake preview widget (exercises the preview path in the view).
  final Widget? preview;

  bool started = false;
  bool stopped = false;

  @override
  Future<void> start(FrameConsumer onFrame) async {
    started = true;
    for (var i = 0; i < frameCount; i++) {
      onFrame(_dummyImage(), 90);
    }
  }

  CameraImage _dummyImage() => CameraImage.fromPlatformInterface(
    CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
      planes: [CameraImagePlane(bytes: _dummyBytes, bytesPerRow: 2)],
      height: 2,
      width: 2,
    ),
  );

  static final Uint8List _dummyBytes = Uint8List(6);

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Widget? buildPreview() => preview;

  @override
  Future<void> flipCamera() async {}

  @override
  Future<void> setTorch(bool enabled) async {}

  @override
  Future<void> setZoom(double zoom) async {}
}

/// Decoder fake: returns all fixture wire frames on the first decode, so the
/// real FrameBuffer + Rust Reassembler receive the exact committed frames in
/// one feed (the view feeds them in order — meta first, then data). The
/// native ML Kit decode itself is device-verified; QR-decode correctness is
/// covered by the interop + painter tests. Resolving everything in one call
/// also keeps the test immune to the fake-async camera timing.
class FakeFrameDecoder implements FrameDecoder {
  FakeFrameDecoder(this.results);

  final List<DecodeResult> results;
  int calls = 0;

  @override
  Future<List<DecodeResult>> decode(
    CameraImage image, {
    required int rotationDegrees,
  }) async {
    if (calls++ == 0) return results;
    return const [];
  }

  @override
  void dispose() {}
}

/// Saver fake: records the bytes handed to saveFile and counts opens.
class FakeSaver {
  final saves = <({Uint8List bytes, String filename, String mime})>[];
  int openCount = 0;
  String? openedName;

  /// When true, [open] throws — exercises the open-failure path.
  bool failOpen = false;

  Future<SaveResult> save({
    required Uint8List bytes,
    required String filename,
    required String mime,
    SaveMethod? method,
  }) async {
    saves.add((bytes: bytes, filename: filename, mime: mime));
    return SaveResult(
      name: filename,
      method: method ?? SaveMethod.mediaStore,
      uri: 'content://media/downloads/1',
    );
  }

  Future<void> open(SaveResult result) async {
    openCount++;
    openedName = result.name;
    if (failOpen) {
      throw SaveException('no viewer for ${result.name}');
    }
  }
}

/// Mounts ReceiveView with the real pipeline and injected fakes.
Widget _harness({
  required CameraService camera,
  required Saver saver,
  required FrameDecoder decoder,
  bool linuxOnly = false,
  ValueChanged<bool>? onImmersiveChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ReceiveView(
        linuxOnly: linuxOnly,
        cameraService: camera,
        saver: saver,
        frameDecoder: decoder,
        onImmersiveChanged: onImmersiveChanged,
      ),
    ),
  );
}

/// Pumps with real async (isolate decodes, FFI) until [ready] holds.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the receive flow');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

/// Locates the Rust dylib regardless of the test working directory.
String? _resolveDylib() {
  const candidates = <String>[
    'rust/target/debug/libqr_transfer_rust.so', // flutter test CWD = flutter_app/
    '../rust/target/debug/libqr_transfer_rust.so',
  ];
  for (final rel in candidates) {
    final file = File(rel);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

void main() {
  setUpAll(() async {
    final dylib = _resolveDylib();
    expect(
      dylib,
      isNotNull,
      reason: 'Rust dylib missing — build flutter_app/rust (cargo build) '
          'before running these tests',
    );
    await ensureRustLib(dylibPath: dylib);
  });

  for (final name in ['random-1k', 'random-64k', 'text-256k']) {
    testWidgets('$name: stats grow → VERIFIED → save (byte-identical) → open', (
      tester,
    ) async {
      final fx = Fixture(name);
      final expectedName = name == 'text-256k' ? 'text-256k.txt' : '$name.bin';
      final k = fx.dataFrames.length;
      final results = <DecodeResult>[
        DecodeResult(bytes: fx.metaFrame),
        for (final frame in fx.dataFrames) DecodeResult(bytes: frame),
      ];
      final camera = FakeCameraService(1);
      final decoder = FakeFrameDecoder(results);
      final fake = FakeSaver();

      await tester.pumpWidget(
        _harness(
          camera: camera,
          saver: Saver(saveFn: fake.save, openFn: fake.open),
          decoder: decoder,
        ),
      );

      // Given: the idle card. When: Start scanning is tapped.
      expect(find.text('Start scanning'), findsOneWidget);
      await tester.tap(find.text('Start scanning'));
      await tester.pump();
      expect(camera.started, isTrue);

      // Then: the live stats reach k/k (unique grew from 0 to k over the
      // stream) and the VERIFIED (SHA-256) badge + Save card appear only
      // after the whole-file hash gate passed.
      await _pumpUntil(
        tester,
        () => find.text('Save file').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 90),
      );
      expect(find.text('$k / $k'), findsOneWidget, reason: 'stats reached k');
      expect(find.textContaining('VERIFIED'), findsOneWidget);

      // When: Save file is tapped. Then: the saver received the exact
      // original bytes and the success card names the file.
      await tester.tap(find.text('Save file'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('File saved'), findsOneWidget);
      expect(find.textContaining(fx.name), findsWidgets);
      expect(fake.saves, hasLength(1));
      expect(fake.saves.single.filename, expectedName);
      expect(fake.saves.single.bytes, equals(fx.original));

      // When: the saved file is tapped. Then: the open path is called.
      await tester.tap(find.text('Open file'));
      await tester.pump();
      expect(fake.openCount, 1);
      expect(fake.openedName, expectedName);
    });
  }

  testWidgets('a failed open surfaces a SnackBar, never an unhandled error', (
    tester,
  ) async {
    final fx = Fixture('random-1k');
    final results = <DecodeResult>[
      DecodeResult(bytes: fx.metaFrame),
      for (final frame in fx.dataFrames) DecodeResult(bytes: frame),
    ];
    final camera = FakeCameraService(1);
    final decoder = FakeFrameDecoder(results);
    final fake = FakeSaver()..failOpen = true;

    await tester.pumpWidget(
      _harness(
        camera: camera,
        saver: Saver(saveFn: fake.save, openFn: fake.open),
        decoder: decoder,
      ),
    );
    await tester.tap(find.text('Start scanning'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.text('Save file').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 90),
    );
    await tester.tap(find.text('Save file'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('File saved'), findsOneWidget);

    // When: the open fails. Then: a SnackBar shows the reason, no crash.
    await tester.tap(find.text('Open file'));
    await tester.pump();
    expect(fake.openCount, 1);
    expect(find.textContaining('Could not open the file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a live camera preview renders while scanning', (tester) async {
    final camera = FakeCameraService(
      0,
      preview: const ColoredBox(key: Key('fake_preview'), color: Colors.green),
    );
    final fake = FakeSaver();
    await tester.pumpWidget(
      _harness(
        camera: camera,
        saver: Saver(saveFn: fake.save, openFn: fake.open),
        decoder: FakeFrameDecoder(const []),
      ),
    );

    await tester.tap(find.text('Start scanning'));
    await tester.pump();

    expect(camera.started, isTrue);
    expect(find.byKey(const Key('fake_preview')), findsOneWidget,
        reason: 'the camera preview fills the scanning stage');
  });

  testWidgets('linuxOnly shows the phone card, no camera, no Start button', (
    tester,
  ) async {
    final camera = FakeCameraService(0);
    final fake = FakeSaver();
    await tester.pumpWidget(
      _harness(
        camera: camera,
        saver: Saver(saveFn: fake.save, openFn: fake.open),
        decoder: FakeFrameDecoder(const []),
        linuxOnly: true,
      ),
    );

    expect(find.textContaining('Receive on your phone'), findsOneWidget);
    expect(find.text('Start scanning'), findsNothing);
    expect(camera.started, isFalse);
    expect(fake.saves, isEmpty);
  });

  testWidgets('notifies immersive while scanning, clears on stop', (tester) async {
    final camera = FakeCameraService(1);
    final decoder = FakeFrameDecoder(const []);
    // Make the first decode throw so scanning exits into the error card
    // (which is what clears the immersive flag on this path).
    final throwing = _ThrowingDecoder(decoder);
    final states = <bool>[];
    await tester.pumpWidget(
      _harness(
        camera: camera,
        saver: Saver(saveFn: FakeSaver().save, openFn: FakeSaver().open),
        decoder: throwing,
        onImmersiveChanged: states.add,
      ),
    );

    // Start scanning -> immersive on (brand header hides in the shell).
    await tester.tap(find.text('Start scanning'));
    await tester.pump();
    expect(states, contains(true));
    expect(camera.started, isTrue);

    // The decode failure lands in the error card -> immersive off.
    await tester.pumpAndSettle();
    expect(states.last, isFalse);
    expect(find.text('Could not scan'), findsOneWidget);
  });
}

/// Delegates to [inner] but throws on the first decode.
class _ThrowingDecoder implements FrameDecoder {
  _ThrowingDecoder(this.inner);

  final FakeFrameDecoder inner;
  bool _thrown = false;

  @override
  Future<List<DecodeResult>> decode(
    CameraImage image, {
    required int rotationDegrees,
  }) async {
    if (!_thrown) {
      _thrown = true;
      throw StateError('decode failed (test)');
    }
    return inner.decode(image, rotationDegrees: rotationDegrees);
  }

  @override
  void dispose() => inner.dispose();
}

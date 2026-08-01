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

import 'package:qr_data_transfer/receiver/camera_service.dart';
import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_data_transfer/ui/receive_view.dart';
import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/receiver/decode_pool.dart';

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

/// Camera fake: yields every [QrMatrix] as a rasterized RGB frame on start,
/// exactly like the PWA's virtual camera feeding the orchestrator.
class FakeCameraService implements CameraService {
  FakeCameraService(this.frames);

  final List<QrMatrix> frames;
  bool started = false;
  bool stopped = false;

  @override
  Future<void> start(FrameConsumer onFrame) async {
    started = true;
    for (final qr in frames) {
      final img = _rasterize(qr, ppm: 2);
      onFrame(img.rgb, img.px, img.px);
    }
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

/// Rasterizes a QR module matrix into tight RGB at [ppm] pixels per module
/// with a [quiet]-module white quiet zone (integer scales, like the sender).
({Uint8List rgb, int px}) _rasterize(QrMatrix qr, {int ppm = 2, int quiet = 4}) {
  final side = qr.size;
  final px = (side + 2 * quiet) * ppm;
  final rgb = Uint8List(px * px * 3);
  for (var y = 0; y < px; y++) {
    for (var x = 0; x < px; x++) {
      final mx = x ~/ ppm - quiet;
      final my = y ~/ ppm - quiet;
      final dark = mx >= 0 &&
          mx < side &&
          my >= 0 &&
          my < side &&
          qr.modules[my * side + mx] == 1;
      final o = (y * px + x) * 3;
      rgb[o] = dark ? 0 : 255;
      rgb[o + 1] = dark ? 0 : 255;
      rgb[o + 2] = dark ? 0 : 255;
    }
  }
  return (rgb: rgb, px: px);
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
  required DecodePool pool,
  bool linuxOnly = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ReceiveView(
        linuxOnly: linuxOnly,
        cameraService: camera,
        saver: saver,
        decodePool: pool,
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
  late DecodePool pool;

  setUpAll(() async {
    final dylib = _resolveDylib();
    expect(
      dylib,
      isNotNull,
      reason: 'Rust dylib missing — build flutter_app/rust (cargo build) '
          'before running these tests',
    );
    await ensureRustLib(dylibPath: dylib);
    pool = DecodePool(size: 2);
    // Prime the worker isolates in the real zone so the fake-async test body
    // never has to wait on Isolate.spawn.
    await pool.decode(Uint8List(3), 1, 1);
  });

  tearDownAll(() => pool.dispose());

  for (final name in ['random-1k', 'random-64k', 'text-256k']) {
    testWidgets('$name: stats grow → VERIFIED → save (byte-identical) → open', (
      tester,
    ) async {
      final fx = Fixture(name);
      final expectedName = name == 'text-256k' ? 'text-256k.txt' : '$name.bin';
      final k = fx.dataFrames.length;
      final camera = FakeCameraService(<QrMatrix>[
        encodeQrBytes(fx.metaFrame, version: 27),
        for (final frame in fx.dataFrames) encodeQrBytes(frame, version: 27),
      ]);
      final fake = FakeSaver();

      await tester.pumpWidget(
        _harness(
          camera: camera,
          saver: Saver(saveFn: fake.save, openFn: fake.open),
          pool: pool,
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
    final camera = FakeCameraService(<QrMatrix>[
      encodeQrBytes(fx.metaFrame, version: 27),
      for (final frame in fx.dataFrames) encodeQrBytes(frame, version: 27),
    ]);
    final fake = FakeSaver()..failOpen = true;

    await tester.pumpWidget(
      _harness(
        camera: camera,
        saver: Saver(saveFn: fake.save, openFn: fake.open),
        pool: pool,
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

  testWidgets('linuxOnly shows the phone card, no camera, no Start button', (
    tester,
  ) async {
    final camera = FakeCameraService(const <QrMatrix>[]);
    final fake = FakeSaver();
    await tester.pumpWidget(
      _harness(
        camera: camera,
        saver: Saver(saveFn: fake.save, openFn: fake.open),
        pool: pool,
        linuxOnly: true,
      ),
    );

    expect(find.textContaining('Receive on your phone'), findsOneWidget);
    expect(find.text('Start scanning'), findsNothing);
    expect(camera.started, isFalse);
    expect(fake.saves, isEmpty);
  });
}

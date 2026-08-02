// Broadcast controller + grid painter widget tests (Wave 3 T3.5).
//
// DECISION: the widget tests use the REAL pipeline + REAL Rust FFI facade
// (ensureRustLib + RustRaptorqFactory in setUpAll), proving the whole chain
// from file bytes → fountain encode → wire frames → QR matrices on the real
// broadcast loop. The Rust dylib is expected at flutter_app/rust/target/debug
// (built by the interop task). The tests that need to spy on the encoder or
// force an encode failure build a PreparedTransfer directly with a fake
// encoder, since those seams are not reachable through the real FFI.
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
// Flutter's widgets export a `LayoutId` (CustomMultiChildLayout) that collides
// with the protocol's tile-layout id, so it is hidden here.
import 'package:flutter/material.dart' hide LayoutId;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_data_transfer/sender/broadcast_controller.dart';
import 'package:qr_data_transfer/ui/qr_grid_painter.dart';
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/sender/encode_worker.dart';
import 'package:qr_transfer_core/sender/pacing.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';

/// Deterministic incompressible bytes (seeded, so runs are repeatable).

/// The pigeon BasicMessageChannel the wakelock_plus plugin uses (pinned by
/// pubspec: wakelock_plus 1.7.0 → platform_interface 1.6.0).
const String _wakelockToggleChannel =
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
Uint8List randomBytes(int length, [int seed = 42]) {
  final rng = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return bytes;
}

/// Fake encoder that only records dispose() — enough for the seams the real
/// FFI encoder cannot exercise (encoder release, oversized-frame encoding).
class _SpyEncoder implements FountainEncoder {
  bool disposed = false;

  @override
  int get sourceSymbolCount => 4;

  @override
  int get symbolSize => 1024;

  @override
  List<EncodedSymbol> encodeSourceSymbols() => const <EncodedSymbol>[];

  @override
  List<EncodedSymbol> encodeRepair(int count) => [
    for (var i = 0; i < count; i++)
      EncodedSymbol(bytes: Uint8List(symbolSize), esi: sourceSymbolCount + i),
  ];

  @override
  void dispose() {
    disposed = true;
  }
}

/// Build a PreparedTransfer directly, bypassing the real pipeline, for tests
/// that need a fake encoder or deliberately oversized frames.
PreparedTransfer _buildPrepared({
  required List<Uint8List> dataFrames,
  required Uint8List metaFrame,
  required int k,
  required FountainEncoder encoder,
}) {
  const settings = TransferSettings(
    bytesPerTile: BytesPerTileId.oneK,
    layout: LayoutId.grid4,
    targetFps: 15,
    highRefresh: false,
  );
  return PreparedTransfer(
    info: TransferInfo(
      sessionId: '0123456789abcdef',
      filename: 'f.bin',
      mime: 'application/octet-stream',
      totalSize: 4096,
      compressedSize: 4096,
      compressed: false,
      k: k,
      symbolSize: 1024,
      mtu: 1028,
      fileSHA256: '0' * 64,
      settings: settings,
      bytesPerTile: BytesPerTileId.oneK,
    ),
    dataFrames: dataFrames,
    metaFrames: <Uint8List>[metaFrame],
    encoder: encoder,
  );
}

/// Locates the Rust dylib regardless of the test's working directory.
String? _resolveDylib() {
  const candidates = <String>[
    'rust/target/debug/libqr_transfer_rust.so', // flutter test CWD = flutter_app/
    '../rust/target/debug/libqr_transfer_rust.so', // dart test CWD = core/
  ];
  for (final rel in candidates) {
    final file = File(rel);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

/// Harness that exposes a [TickerProvider] to the controller, so the ticker
/// runs under the widget-test clock.
class _TickerHost extends StatefulWidget {
  const _TickerHost({required this.builder});

  final Widget Function(BuildContext context, TickerProvider provider) builder;

  @override
  State<_TickerHost> createState() => _TickerHostState();
}

class _TickerHostState extends State<_TickerHost>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => widget.builder(context, this);
}

/// Synchronous [EncodeBackend] for tests: encodes on request and answers
/// immediately, so the controller behaves exactly like the old inline encode
/// path under fake-async pumps (a real isolate's replies would never land).
class _SyncEncodeBackend implements EncodeBackend {
  _SyncEncodeBackend({required this.version});

  final int version;
  final List<(int, List<QrMatrix?>)> _ready = [];

  // Mirrors the real QrEncodeWorker's per-esi cache: identical wire frames
  // (the round-robin revisits the same k source symbols) must not be
  // re-encoded, otherwise the first tick encodes lookahead × tiles V27 QR
  // matrices synchronously and, on a slow CI machine, trips the fps
  // adaptation that shifts the cadence expectations below.
  final Map<String, QrMatrix?> _cache = {};

  /// Pre-encodes every distinct wire frame so the controller's timed section
  /// does zero encoding work. The real worker runs in a background isolate, so
  /// encode cost never blocks the display loop; the sync test backend would
  /// otherwise pay that cost inside the timing-sensitive tick and, on a slow
  /// machine, trip the fps adaptation that shifts cadence expectations.
  void warmUp(Iterable<Uint8List?> frames) {
    for (final bytes in frames) {
      _encode(bytes);
    }
  }

  @override
  void requestFrame({
    required int frameIndex,
    required List<int> esis,
    required List<Uint8List?> frameBytes,
  }) {
    _ready.add((frameIndex, [for (final bytes in frameBytes) _encode(bytes)]));
  }

  QrMatrix? _encode(Uint8List? bytes) {
    if (bytes == null) return null;
    final key = String.fromCharCodes(bytes);
    return _cache.putIfAbsent(key, () {
      try {
        return encodeQrBytes(bytes, version: version);
      } on Exception {
        return null;
      }
    });
  }

  @override
  List<(int, List<QrMatrix?>)> drain() {
    if (_ready.isEmpty) return const [];
    final out = List<(int, List<QrMatrix?>)>.of(_ready);
    _ready.clear();
    return out;
  }

  @override
  void dispose() {}
}

void main() {
  late PreparedTransfer sharedPrepared;

  setUpAll(() async {
    final dylib = _resolveDylib();
    expect(
      dylib,
      isNotNull,
      reason:
          'Rust dylib missing — build flutter_app/rust (cargo build) '
          'before running these tests',
    );
    await ensureRustLib(dylibPath: dylib);
    sharedPrepared = await prepareTransfer(
      file: randomBytes(2048),
      filename: 'broadcast.bin',
      mime: 'application/octet-stream',
      factory: RustRaptorqFactory(),
    );
  });

  setUp(() {
    // The controller calls WakelockPlus.enable()/disable() (a pigeon platform
    // channel) on start/stop. Without a mock the reply is a pending future,
    // and on a slow CI runner the ticker teardown can trip "animation still
    // running" at the end of the test. Mock the channel so the wake-lock
    // futures resolve immediately and deterministically.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          _wakelockToggleChannel,
          (_) async => StandardMessageCodec().encodeMessage(const <Object?>[null]),
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(_wakelockToggleChannel, null);
    });
  });

  /// Mounts the ticker harness and creates a controller over [prepared]
  /// (default: the real shared transfer) with the given [settings] (default:
  /// the transfer's own settings).
  Future<BroadcastController> spawnController(
    WidgetTester tester, {
    PreparedTransfer? prepared,
    ValueChanged<SenderStats>? onStats,
    TransferSettings? settings,
  }) async {
    late TickerProvider vsync;
    await tester.pumpWidget(
      _TickerHost(
        builder: (context, provider) {
          vsync = provider;
          return const SizedBox.shrink();
        },
      ),
    );
    final transfer = prepared ?? sharedPrepared;
    final effectiveSettings = settings ?? transfer.info.settings;
    final backend = _SyncEncodeBackend(
      version: bytesPerTile[effectiveSettings.bytesPerTile]!.version,
    );
    // Encode once, up front: the timed section below must be pure cadence, not
    // encode cost (the real worker encodes in a background isolate).
    backend.warmUp(<Uint8List?>[...transfer.dataFrames, ...transfer.metaFrames]);
    return BroadcastController(
      prepared: transfer,
      settings: effectiveSettings,
      vsync: vsync,
      onStats: onStats,
      encode: backend,
    );
  }

  group('BroadcastController', () {
    testWidgets(
      'tickCount grows at the frame-delay cadence (default grid4/15 → 67ms)',
      (tester) async {
        final controller = await spawnController(tester);
        controller.start();

        // The Ticker's first tick only establishes the start time (elapsed 0),
        // mirroring the PWA's first-rAF-frame skip. With the default grid4/15
        // settings the frame delay is 67ms, so 42ms pumps render one frame per
        // two pumps.
        await tester.pump(const Duration(milliseconds: 42));
        expect(controller.tickCount, 0, reason: 'first tick sets the start');
        await tester.pump(const Duration(milliseconds: 42));
        expect(controller.tickCount, 0, reason: '42ms < 67ms frame delay');
        await tester.pump(const Duration(milliseconds: 42)); // elapsed 84ms
        expect(controller.tickCount, 1);
        await tester.pump(const Duration(milliseconds: 42));
        expect(controller.tickCount, 1, reason: 'early tick is skipped');
        await tester.pump(const Duration(milliseconds: 42)); // elapsed 168ms
        expect(controller.tickCount, 2);
        await tester.pump(const Duration(milliseconds: 42));
        expect(controller.tickCount, 2, reason: 'early tick is skipped');
        await tester.pump(const Duration(milliseconds: 42)); // elapsed 252ms
        expect(controller.tickCount, 3);

        // The cadence never exceeds the resolved fps ceiling (15 for the
        // default grid4 settings).
        expect(controller.currentFps, lessThanOrEqualTo(15));

        controller.stop();
        controller.dispose();
      },
    );

    testWidgets('META frame occupies slot 0 at ticks 0, 32 and 64', (
      tester,
    ) async {
      final controller = await spawnController(tester);
      controller.start();
      // 67ms pumps == one frame-delay per pump (15fps → 67ms); the first pump
      // establishes the ticker start, the second renders frame 0.
      const tick = Duration(milliseconds: 67);

      await tester.pump(tick);
      expect(controller.tickCount, 0, reason: 'first tick sets the start');
      await tester.pump(tick); // frame 0
      expect(controller.tickCount, 1);
      expect(controller.lastFrameMeta, isTrue);
      expect(controller.currentFrame, hasLength(controller.tilesPerFrame));
      // Slot 0 is byte-identical to a fresh encode of the META frame.
      final metaQr = encodeQrBytes(
        sharedPrepared.metaFrames.first,
        version: controller.version,
      );
      final slot0 = controller.currentFrame.first!;
      expect(slot0.size, metaQr.size);
      expect(listEquals(slot0.modules, metaQr.modules), isTrue);

      for (var i = 0; i < 31; i++) {
        await tester.pump(tick); // frames 1..31
      }
      expect(controller.tickCount, 32);
      expect(
        controller.lastFrameMeta,
        isFalse,
        reason: 'frame 31 is data-only',
      );
      expect(controller.currentFrame, hasLength(controller.tilesPerFrame));

      await tester.pump(tick); // frame 32
      expect(controller.tickCount, 33);
      expect(controller.lastFrameMeta, isTrue);
      expect(controller.currentFrame.first, isNotNull);

      for (var i = 0; i < 31; i++) {
        await tester.pump(tick); // frames 33..63
      }
      expect(controller.tickCount, 64);
      expect(controller.lastFrameMeta, isFalse);
      await tester.pump(tick); // frame 64
      expect(controller.tickCount, 65);
      expect(controller.lastFrameMeta, isTrue);
      expect(controller.currentFrame.first, isNotNull);

      controller.stop();
      controller.dispose();
    });

    testWidgets('stats emit roughly every 500ms with the transfer fields', (
      tester,
    ) async {
      final stats = <SenderStats>[];
      final controller = await spawnController(tester, onStats: stats.add);
      controller.start();

      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 67)); // 536ms total
      }

      expect(stats, isNotEmpty);
      final last = stats.last;
      expect(last.k, sharedPrepared.info.k);
      expect(last.layout, sharedPrepared.info.settings.layout);
      expect(last.layout, LayoutId.grid4);
      expect(last.tickCount, greaterThan(0));
      expect(last.fps, greaterThan(0));
      expect(last.fps, lessThanOrEqualTo(15));

      controller.stop();
      controller.dispose();
    });

    testWidgets('round-robin esi schedule is deterministic per frame', (
      tester,
    ) async {
      final controller = await spawnController(tester);
      controller.start();

      await tester.pump(const Duration(milliseconds: 67)); // sets the start
      await tester.pump(const Duration(milliseconds: 67)); // frame 0 (meta)
      // Meta tick: 3 data tiles, slot 0 is META; esi schedule starts at 0.
      expect(controller.lastFrameMeta, isTrue);
      expect(controller.lastEsis, <int>[0, 1, 2]);

      await tester.pump(const Duration(milliseconds: 67)); // frame 1 (data)
      expect(controller.lastFrameMeta, isFalse);
      expect(controller.lastEsis, <int>[4, 5, 6, 7]);

      controller.stop();
      controller.dispose();
    });

    testWidgets('dispose() releases the RaptorQ encoder (spy)', (tester) async {
      final spy = _SpyEncoder();
      final prepared = _buildPrepared(
        dataFrames: List<Uint8List>.generate(4, (_) => Uint8List(100)),
        metaFrame: Uint8List(100),
        k: 4,
        encoder: spy,
      );
      final controller = await spawnController(tester, prepared: prepared);
      controller.dispose();
      expect(spy.disposed, isTrue);
      // Idempotent: a second dispose does not throw.
      controller.dispose();
    });

    testWidgets('encode failure → null tile and droppedTicks increment', (
      tester,
    ) async {
      // 3000 bytes does not fit a V27 QR (1465-byte capacity at Ecc.LOW).
      final oversized = Uint8List(3000);
      final prepared = _buildPrepared(
        dataFrames: List<Uint8List>.generate(4, (_) => oversized),
        metaFrame: Uint8List(100),
        k: 4,
        encoder: _SpyEncoder(),
      );
      final controller = await spawnController(tester, prepared: prepared);
      controller.start();

      await tester.pump(const Duration(milliseconds: 67)); // sets the start
      await tester.pump(const Duration(milliseconds: 67)); // frame 0 (meta)
      expect(controller.lastFrameMeta, isTrue);
      expect(controller.currentFrame, hasLength(4));
      expect(controller.currentFrame[0], isNotNull, reason: 'META fits V27');
      expect(controller.currentFrame[1], isNull);
      expect(controller.currentFrame[2], isNull);
      expect(controller.currentFrame[3], isNull);
      expect(controller.droppedTicks, 3);

      controller.stop();
      controller.dispose();
    });
  });

  group('dual-lane (row2/column2)', () {
    const row2Settings = TransferSettings(
      bytesPerTile: BytesPerTileId.oneK,
      layout: LayoutId.row2,
      targetFps: 15,
      highRefresh: false,
    );
    const column2Settings = TransferSettings(
      bytesPerTile: BytesPerTileId.oneK,
      layout: LayoutId.column2,
      targetFps: 15,
      highRefresh: false,
    );

    /// Renders frames 0..[frames-1] and returns each frame's esi schedule.
    Future<List<List<int>>> driveEsis(
      WidgetTester tester, {
      required TransferSettings settings,
      required int frames,
    }) async {
      final controller = await spawnController(tester, settings: settings);
      final history = <List<int>>[];
      for (var i = 0; i < frames; i++) {
        controller.renderFrame(i);
        history.add(List.of(controller.lastEsis));
      }
      controller.stop();
      controller.dispose();
      return history;
    }

    testWidgets('row2: even ticks update lane 0, odd ticks lane 1', (
      tester,
    ) async {
      final esis = await driveEsis(tester, settings: row2Settings, frames: 8);
      expect(
        esis.every((e) => e.length == 2),
        isTrue,
        reason: 'dual-lane frames are exactly 2 tiles',
      );
      // Lane 0 updates on even ticks and holds on the following odd tick.
      expect(esis[0][0], isNot(esis[2][0]), reason: 'lane 0 updates on tick 2');
      expect(esis[2][0], isNot(esis[4][0]), reason: 'lane 0 updates on tick 4');
      expect(esis[4][0], isNot(esis[6][0]), reason: 'lane 0 updates on tick 6');
      expect(esis[0][0], esis[1][0], reason: 'lane 0 holds on tick 0→1');
      expect(esis[2][0], esis[3][0], reason: 'lane 0 holds on tick 2→3');
      expect(esis[4][0], esis[5][0], reason: 'lane 0 holds on tick 4→5');
      expect(esis[6][0], esis[7][0], reason: 'lane 0 holds on tick 6→7');
      // Lane 1 updates on odd ticks and holds on the following even tick.
      expect(esis[1][1], isNot(esis[3][1]), reason: 'lane 1 updates on tick 3');
      expect(esis[3][1], isNot(esis[5][1]), reason: 'lane 1 updates on tick 5');
      expect(esis[5][1], isNot(esis[7][1]), reason: 'lane 1 updates on tick 7');
      expect(esis[1][1], esis[2][1], reason: 'lane 1 holds on tick 1→2');
      expect(esis[3][1], esis[4][1], reason: 'lane 1 holds on tick 3→4');
      expect(esis[5][1], esis[6][1], reason: 'lane 1 holds on tick 5→6');
      // Lanes never show the same esi on one tick.
      for (var i = 0; i < esis.length; i++) {
        expect(esis[i][0], isNot(esis[i][1]), reason: 'tick $i lanes distinct');
      }
    });

    testWidgets('each lane stays constant between its updates', (tester) async {
      final controller = await spawnController(tester, settings: row2Settings);
      controller.renderFrame(0);
      final esis0 = List.of(controller.lastEsis);
      controller.renderFrame(1);
      final esis1 = List.of(controller.lastEsis);
      controller.renderFrame(2);
      final esis2 = List.of(controller.lastEsis);
      expect(esis1[0], esis0[0], reason: 'lane 0 holds across ticks 0→1');
      expect(esis2[1], esis1[1], reason: 'lane 1 holds across ticks 1→2');
      expect(controller.lastEsis, hasLength(2));
      controller.stop();
      controller.dispose();
    });

    testWidgets(
      'meta tick puts META in slot 0 only; slot 1 still carries data',
      (tester) async {
        final controller = await spawnController(
          tester,
          settings: row2Settings,
        );
        for (var i = 0; i < 32; i++) {
          controller.renderFrame(i);
        }
        expect(
          controller.lastFrameMeta,
          isFalse,
          reason: 'frame 31 is data-only',
        );
        controller.renderFrame(32);
        expect(
          controller.lastFrameMeta,
          isTrue,
          reason: 'frame 32 is a meta tick',
        );
        expect(controller.lastEsis, hasLength(2));
        // Slot 0 is byte-identical to a fresh encode of the META frame.
        final metaQr = encodeQrBytes(
          sharedPrepared.metaFrames.first,
          version: controller.version,
        );
        final slot0 = controller.currentFrame.first!;
        expect(slot0.size, metaQr.size);
        expect(listEquals(slot0.modules, metaQr.modules), isTrue);
        // Slot 1 still carries its scheduled data esi (a valid pool index).
        final k = sharedPrepared.info.k;
        final repair = (k * repairExtraFactor).ceil() + repairExtraMin;
        final expected = nextEsiDualLane(k, repair, 32);
        expect(
          controller.lastEsis[1],
          expected[1],
          reason: 'slot 1 is the lane-1 data esi of the dual-lane schedule',
        );
        expect(controller.lastEsis[1], greaterThanOrEqualTo(0));
        expect(
          controller.currentFrame[1],
          isNotNull,
          reason: 'slot 1 QR encoded',
        );
        controller.stop();
        controller.dispose();
      },
    );

    testWidgets(
      'all emitted esis resolve via the FramePool across a full cycle',
      (tester) async {
        final controller = await spawnController(
          tester,
          settings: row2Settings,
        );
        final k = sharedPrepared.info.k;
        final repair = (k * repairExtraFactor).ceil() + repairExtraMin;
        final poolSize = k + repair;
        var sawRepair = false;
        for (var i = 0; i < 2 * poolSize; i++) {
          // A RangeError/StateError here means a scheduled esi could not
          // resolve via the FramePool (missing source / beyond the repair
          // cache).
          controller.renderFrame(i);
          final esis = controller.lastEsis;
          expect(esis, hasLength(2));
          for (final esi in esis) {
            expect(
              esi,
              inInclusiveRange(0, poolSize - 1),
              reason: 'frame $i slot must be a valid pool index',
            );
            if (esi >= k) sawRepair = true;
          }
        }
        expect(
          sawRepair,
          isTrue,
          reason: 'repair esis (>= k) appear over a full cycle',
        );
        controller.stop();
        controller.dispose();
      },
    );

    testWidgets('column2 behaves identically', (tester) async {
      // One controller drives the whole test (the ticker harness is a single
      // TickerProvider, so a second controller in the same test is not allowed).
      final controller = await spawnController(
        tester,
        settings: column2Settings,
      );
      final esis = <List<int>>[];
      for (var i = 0; i < 6; i++) {
        controller.renderFrame(i);
        esis.add(List.of(controller.lastEsis));
      }
      expect(esis, hasLength(6));
      expect(esis.every((e) => e.length == 2), isTrue);
      // Lane 0 updates on even ticks, lane 1 on odd; each holds its esi for
      // exactly 2 ticks — the same dual-lane schedule as row2.
      expect(
        esis[0][0],
        isNot(esis[2][0]),
        reason: 'lane 0 updates on even tick 2',
      );
      expect(
        esis[2][0],
        isNot(esis[4][0]),
        reason: 'lane 0 updates on even tick 4',
      );
      expect(esis[0][0], esis[1][0], reason: 'lane 0 holds on tick 0→1');
      expect(esis[2][0], esis[3][0], reason: 'lane 0 holds on tick 2→3');
      expect(
        esis[1][1],
        isNot(esis[3][1]),
        reason: 'lane 1 updates on odd tick 3',
      );
      expect(esis[1][1], esis[2][1], reason: 'lane 1 holds on tick 1→2');
      expect(esis[3][1], esis[4][1], reason: 'lane 1 holds on tick 3→4');
      for (var i = 0; i < esis.length; i++) {
        expect(esis[i][0], isNot(esis[i][1]), reason: 'tick $i lanes distinct');
      }
      // column2 meta tick: META in slot 0, slot 1 data.
      for (var i = 6; i <= 32; i++) {
        controller.renderFrame(i);
      }
      expect(controller.lastFrameMeta, isTrue);
      expect(controller.lastEsis, hasLength(2));
      final k = sharedPrepared.info.k;
      final repair = (k * repairExtraFactor).ceil() + repairExtraMin;
      final expected = nextEsiDualLane(k, repair, 32);
      expect(controller.lastEsis[1], expected[1]);
      expect(
        controller.currentFrame.first,
        isNotNull,
        reason: 'META QR encoded',
      );
      controller.stop();
      controller.dispose();
    });
  });

  group('QrGridPainter', () {
    testWidgets('paints white modules on an espresso background', (
      tester,
    ) async {
      final controller = await spawnController(tester);
      controller.start();
      await tester.pump(const Duration(milliseconds: 67)); // sets the start
      await tester.pump(const Duration(milliseconds: 67)); // one real frame
      final tiles = controller.currentFrame;
      expect(tiles, hasLength(controller.tilesPerFrame));
      expect(tiles.every((t) => t != null), isTrue);

      final painter = QrGridPainter(
        tiles: tiles,
        layout: controller.settings.layout,
        version: controller.version,
        repaint: controller.frameSignal,
      );

      // shouldRepaint follows the tile list / geometry identity.
      expect(
        painter.shouldRepaint(
          QrGridPainter(
            tiles: tiles,
            layout: controller.settings.layout,
            version: controller.version,
          ),
        ),
        isFalse,
        reason: 'same tile list → no repaint',
      );
      expect(
        painter.shouldRepaint(
          QrGridPainter(
            tiles: const <QrMatrix?>[],
            layout: controller.settings.layout,
            version: controller.version,
          ),
        ),
        isTrue,
        reason: 'new tile list → repaint',
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      painter.paint(canvas, const ui.Size(400, 400));
      final picture = recorder.endRecording();

      await tester.runAsync(() async {
        final image = await picture.toImage(400, 400);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final bytes = data!.buffer.asUint8List();
        // Cell corners sit in the always-dark espresso background (#161312).
        expect(bytes[0], 0x16);
        expect(bytes[1], 0x13);
        expect(bytes[2], 0x12);
        expect(bytes[3], 0xFF);
        // Dark QR modules render as white fills, so at least one white pixel
        // exists (finder patterns guarantee dark modules).
        var hasWhite = false;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i] == 0xFF &&
              bytes[i + 1] == 0xFF &&
              bytes[i + 2] == 0xFF) {
            hasWhite = true;
            break;
          }
        }
        expect(hasWhite, isTrue, reason: 'no white module pixels rendered');
        image.dispose();
      });
      picture.dispose();

      controller.stop();
      controller.dispose();
    });
  });
}

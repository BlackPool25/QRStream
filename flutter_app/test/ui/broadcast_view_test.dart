// BroadcastView widget tests (Wave 5 T5.4).
//
// The prepared transfer is built through the REAL core pipeline with a FAKE
// fountain factory (no Rust dylib required): the fake encoder hands out real
// source/repair symbol bytes — small enough to QR-encode at V27 — and records
// dispose(), so the tests can prove the controller releases the encoder when
// Stop is tapped. The wake lock is mocked at the pigeon message-channel level:
// the wakelock_plus plugin's `wakelockPlusPlatformInstance` seam is typed to a
// package this app does not depend on, so the test intercepts the plugin's
// toggle channel and records the decoded `enable` payloads.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide LayoutId;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_data_transfer/theme/app_theme.dart';
import 'package:qr_data_transfer/ui/broadcast_view.dart';
import 'package:qr_data_transfer/ui/qr_grid_painter.dart';
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';
import 'package:qr_transfer_core/sender/settings.dart';

/// The pigeon BasicMessageChannel the wakelock_plus plugin uses (pinned by
/// pubspec: wakelock_plus 1.7.0 → platform_interface 1.6.0).
const String _wakelockToggleChannel =
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

/// Deterministic incompressible bytes so deflate leaves the payload alone.
Uint8List _randomBytes(int length, [int seed = 42]) {
  final rng = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}

/// Fake encoder: real source/repair symbol bytes (QR-encodable at V27) and a
/// dispose() spy. `encodeRepair` returns the K-source prefix + `count` repair
/// symbols, exactly like the Rust facade.
class _FakeEncoder implements FountainEncoder {
  _FakeEncoder({required this.symbolSize}) {
    for (var esi = 0; esi < sourceSymbolCount; esi++) {
      _sources.add(EncodedSymbol(bytes: _symbolBytes(esi), esi: esi));
    }
  }

  @override
  final int symbolSize;
  final List<EncodedSymbol> _sources = <EncodedSymbol>[];
  int disposeCount = 0;

  @override
  int get sourceSymbolCount => 4;

  @override
  List<EncodedSymbol> encodeSourceSymbols() => _sources;

  @override
  List<EncodedSymbol> encodeRepair(int count) => <EncodedSymbol>[
        ..._sources,
        for (var i = 0; i < count; i++)
          EncodedSymbol(
            bytes: _symbolBytes(sourceSymbolCount + i),
            esi: sourceSymbolCount + i,
          ),
      ];

  @override
  void dispose() {
    disposeCount += 1;
  }

  Uint8List _symbolBytes(int esi) {
    final bytes = Uint8List(symbolSize);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (esi * 31 + i) & 0xFF;
    }
    return bytes;
  }
}

/// Fake factory recording createEncoder calls; [lastEncoder] is the dispose
/// spy the pipeline produced.
class _FakeFactory implements FountainFactory {
  _FakeEncoder? lastEncoder;
  int createCount = 0;

  @override
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu) async {
    createCount += 1;
    return lastEncoder = _FakeEncoder(symbolSize: mtu - 4);
  }

  @override
  Future<FountainDecoder> createDecoder(int totalLength, int mtu) =>
      throw UnimplementedError('sender-only fake');
}

/// Builds a real prepared transfer through the core pipeline with the fake
/// factory.
Future<PreparedTransfer> _buildPrepared({_FakeFactory? factory}) =>
    prepareTransfer(
      file: _randomBytes(2048),
      filename: 'f.bin',
      mime: 'application/octet-stream',
      factory: factory ?? _FakeFactory(),
    );

/// Decodes the `enable` bool from a pigeon ToggleMessage payload: the outer
/// StandardCodec list holds one ToggleMessage, which itself encodes as the
/// list `[enable]` (see wakelock_plus_platform_interface messages.g.dart).
/// Byte order and list sizes follow StandardMessageCodec's expanding 1-5 byte
/// `writeSize` (host endian) — both sizes are 1 here.
bool? _decodeToggleEnable(ByteData? message) {
  if (message == null) return null;
  final view = ByteData.sublistView(message);
  if (view.getUint8(0) != 12) return null; // _valueList
  if (_readSize(view, 1) != 1) return null;
  if (view.getUint8(2) != 129) return null; // ToggleMessage custom tag
  if (view.getUint8(3) != 12) return null; // inner [enable] list
  if (_readSize(view, 4) != 1) return null;
  switch (view.getUint8(5)) {
    case 1: // _valueTrue
      return true;
    case 2: // _valueFalse
      return false;
    default:
      return null;
  }
}

/// Inverse of `StandardMessageCodec.writeSize`: an expanding 1-5 byte
/// non-negative integer, small values in a single byte.
int _readSize(ByteData view, int offset) {
  final value = view.getUint8(offset);
  return switch (value) {
    254 => view.getUint16(offset + 1, Endian.host),
    255 => view.getUint32(offset + 1, Endian.host),
    _ => value,
  };
}

Future<void> _pumpView(
  WidgetTester tester,
  PreparedTransfer prepared, {
  VoidCallback? onStop,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: BroadcastView(
        prepared: prepared,
        settings: prepared.info.settings,
        onStop: onStop ?? () {},
      ),
    ),
  );
}

void main() {
  testWidgets('renders the QR stage and status chips from live stats', (
    tester,
  ) async {
    final prepared = await _buildPrepared();

    await _pumpView(tester, prepared);

    // Before the first stats window the overlay shows a starting chip only.
    expect(find.text('Starting…'), findsOneWidget);

    // The stage paints the current frame through the controller's painter.
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is QrGridPainter,
      ),
      findsOneWidget,
    );

    // ~500ms of ticker time → the first SenderStats → the full chip set.
    for (var i = 0; i < 9; i++) {
      await tester.pump(const Duration(milliseconds: 67));
    }

    expect(find.text('f.bin'), findsOneWidget);
    expect(find.text(transferLabel(prepared.info.settings)), findsOneWidget);
    expect(find.text('0 dropped'), findsOneWidget);
    expect(find.textContaining('fps'), findsOneWidget);
    expect(find.textContaining('/s'), findsOneWidget); // live rate chip
  });

  testWidgets('the stage background stays espresso under a light app theme', (
    tester,
  ) async {
    final prepared = await _buildPrepared();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.pink),
        ),
        home: BroadcastView(
          prepared: prepared,
          settings: prepared.info.settings,
          onStop: () {},
        ),
      ),
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, qrStageBackground);
    expect(scaffold.backgroundColor, QrGridPainter.espresso);
  });

  testWidgets('boost toggles the wake lock on and off', (tester) async {
    final prepared = await _buildPrepared();
    final toggles = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      _wakelockToggleChannel,
      (ByteData? message) async {
        final enable = _decodeToggleEnable(message);
        if (enable != null) toggles.add(enable);
        return StandardMessageCodec().encodeMessage(const <Object?>[null]);
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        _wakelockToggleChannel,
        null,
      );
    });

    await _pumpView(tester, prepared);

    expect(find.byIcon(Icons.brightness_low), findsOneWidget);
    await tester.tap(find.text('Boost'));
    await tester.pump();
    expect(find.byIcon(Icons.brightness_high), findsOneWidget);
    expect(toggles, <bool>[true]);

    await tester.tap(find.text('Boost'));
    await tester.pump();
    expect(find.byIcon(Icons.brightness_low), findsOneWidget);
    expect(toggles, <bool>[true, false]);
  });

  testWidgets('stop calls onStop and disposes the encoder (factory spy)', (
    tester,
  ) async {
    final factory = _FakeFactory();
    final prepared = await _buildPrepared(factory: factory);
    var stops = 0;

    await _pumpView(tester, prepared, onStop: () => stops += 1);

    await tester.tap(find.text('Stop'));
    await tester.pump();

    expect(stops, 1);
    expect(
      factory.createCount,
      1,
      reason: 'pipeline used the injected factory',
    );
    expect(factory.lastEncoder?.disposeCount, 1, reason: 'encoder freed');
  });
}

// README marketing screenshots — renders the REAL Flutter UI (brown M3 theme,
// Fraunces display type, real QR matrices) and writes PNGs under
// ../../docs/screenshots/flutter-*.png via golden capture.
//
// Run: cd flutter_app && flutter test test/ui/readme_screenshots_test.dart --update-goldens
//
// Fonts: widget tests render with the Ahem placeholder font by default, so the
// bundled Fraunces face is loaded explicitly to get real display text. The
// Material icon font is loaded too (the shell/broadcast UI uses icons).
//
// The transfer is built through the REAL core pipeline with a fake fountain
// factory (no Rust dylib needed): the fake encoder hands out real symbol bytes
// that QR-encode at V27, so the grid painter draws genuine QR matrices.

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart' hide LayoutId;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_data_transfer/shell/app_shell.dart';
import 'package:qr_data_transfer/theme/app_theme.dart';
import 'package:qr_data_transfer/ui/broadcast_view.dart';
import 'package:qr_data_transfer/ui/settings_panel.dart';
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/sender/encode_worker.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';
import 'package:qr_transfer_core/sender/settings.dart';

const String _frauncesAsset = 'assets/fonts/Fraunces-VariableFont_opsz,wght.ttf';

/// Synchronous encode backend so the broadcast loop runs under fake async.
class _SyncEncodeBackend implements EncodeBackend {
  _SyncEncodeBackend({required this.version});

  final int version;
  final List<(int, List<QrMatrix?>)> _ready = [];

  @override
  void requestFrame({
    required int frameIndex,
    required List<int> esis,
    required List<Uint8List?> frameBytes,
  }) {
    _ready.add((
      frameIndex,
      [
        for (final bytes in frameBytes)
          bytes == null
              ? null
              : (() {
                  try {
                    return encodeQrBytes(bytes, version: version);
                  } on Exception {
                    return null;
                  }
                })(),
      ],
    ));
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

class _FakeEncoder implements FountainEncoder {
  _FakeEncoder({required this.symbolSize}) {
    for (var esi = 0; esi < sourceSymbolCount; esi++) {
      _sources.add(EncodedSymbol(bytes: _symbolBytes(esi), esi: esi));
    }
  }

  @override
  final int symbolSize;
  final List<EncodedSymbol> _sources = <EncodedSymbol>[];

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
  void dispose() {}

  Uint8List _symbolBytes(int esi) {
    final bytes = Uint8List(symbolSize);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (esi * 31 + i) & 0xFF;
    }
    return bytes;
  }
}

class _FakeFactory implements FountainFactory {
  @override
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu) async {
    return _FakeEncoder(symbolSize: mtu - 4);
  }

  @override
  Future<FountainDecoder> createDecoder(int totalLength, int mtu) {
    throw UnsupportedError('readme screenshot test never decodes');
  }
}

Uint8List _randomBytes(int length, [int seed = 7]) {
  final rng = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}

Future<void> _loadFonts() async {
  final fraunces = File(_frauncesAsset).readAsBytesSync();
  final frauncesLoader = FontLoader('Fraunces')
    ..addFont(Future.value(ByteData.view(fraunces.buffer)));
  await frauncesLoader.load();
}

Future<(PreparedTransfer, qrc.TransferSettings)> _prepare() async {
  final settings = defaultTransferSettings;
  final transfer = await prepareTransfer(
    file: _randomBytes(2048),
    filename: 'photo-album.zip',
    mime: 'application/zip',
    settings: settings,
    factory: _FakeFactory(),
  );
  return (transfer, settings);
}

/// A golden comparator that always writes the captured image and never fails —
/// this file is a README screenshot *capture* tool, not a pixel regression
/// test. The broadcast view is animated (QR tiles cycle on a real clock), so a
/// comparison would fail on every run by design.
class _WriteOnlyComparator extends LocalFileComparator {
  _WriteOnlyComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    File(golden.toFilePath()).createSync(recursive: true);
    File(golden.toFilePath()).writeAsBytesSync(imageBytes);
    return true;
  }
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    goldenFileComparator = _WriteOnlyComparator(
      Uri.file('${Directory.current.path}/bogus.png'),
    );
  });

  testWidgets('capture the broadcast view (2×2 QR grid, dark stage)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.devicePixelRatio = 1.0;
    final (transfer, settings) = await _prepare();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: BroadcastView(
          prepared: transfer,
          settings: settings,
          onStop: () {},
          encodeBackend: _SyncEncodeBackend(version: 27),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(
      find.byType(BroadcastView),
      matchesGoldenFile('../../docs/screenshots/flutter-broadcast.png'),
    );
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('capture the send-flow settings panel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: SettingsPanel(
            settings: defaultTransferSettings,
            onChanged: (_) {},
            compressedSize: 4 * 1024 * 1024,
            refreshRate: 60,
            suggestedLayout: qrc.LayoutId.grid4,
            onBegin: () {},
            onDifferentFile: () {},
            fileName: 'photo-album.zip',
            fileSize: 8 * 1024 * 1024,
          ),
        ),
      ),
    );
    await tester.pump();
    await expectLater(
      find.byType(SettingsPanel),
      matchesGoldenFile('../../docs/screenshots/flutter-settings.png'),
    );
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('capture the app shell (send/receive nav, brand header)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: AppShell(linuxOnly: true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(AppShell),
      matchesGoldenFile('../../docs/screenshots/flutter-shell.png'),
    );
    await tester.binding.setSurfaceSize(null);
  });
}

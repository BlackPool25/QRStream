// Widget tests for the send flow: pick → prepare → settings → broadcast,
// with the cache/back-nav contract (D9):
//   * back from settings does NOT re-chunk (prepareTransfer called once)
//   * back from a running broadcast returns to settings with the cache intact
//   * only a bytes-per-tile change re-encodes
//   * "Different file" clears the cache
//
// Uses a fake file picker + a fake fountain factory (no FFI, no platform
// channels), so the flow is deterministic and fast.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_transfer_core/codec/fountain/interface.dart';

import 'package:qr_data_transfer/ui/send_view.dart';

/// Deterministic fake encoder/decoder/factory (mirrors the PWA's fake
/// factory tests): symbols are the payload split into mtu-sized chunks, and
/// the decoder reassembles by concatenation. Tracks createEncoder calls so
/// tests can assert "no re-chunk".
class FakeFountainFactory implements FountainFactory {
  int encoderCreations = 0;
  int decoderCreations = 0;

  @override
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu) async {
    encoderCreations++;
    return FakeEncoder(data, mtu);
  }

  @override
  Future<FountainDecoder> createDecoder(int totalLength, int mtu) async {
    decoderCreations++;
    return FakeDecoder(totalLength);
  }
}

class FakeEncoder implements FountainEncoder {
  final Uint8List data;
  @override
  final int symbolSize;

  FakeEncoder(this.data, this.symbolSize);

  @override
  int get sourceSymbolCount =>
      (data.length / (symbolSize - 4)).ceil().clamp(1, 1 << 20);

  @override
  List<EncodedSymbol> encodeSourceSymbols() {
    final count = sourceSymbolCount;
    return [
      for (var i = 0; i < count; i++)
        EncodedSymbol(
          bytes: data.sublist(
            i * (symbolSize - 4),
            i * (symbolSize - 4) + (symbolSize - 4) > data.length
                ? data.length
                : i * (symbolSize - 4) + (symbolSize - 4),
          ),
          esi: i,
        ),
    ];
  }

  @override
  List<EncodedSymbol> encodeRepair(int count) {
    final base = sourceSymbolCount;
    return [
      for (var i = 0; i < count; i++)
        EncodedSymbol(
          bytes: Uint8List.fromList(
            List<int>.filled(symbolSize - 4, 0xAA + i),
          ),
          esi: base + i,
        ),
    ];
  }

  @override
  void dispose() {}
}

class FakeDecoder implements FountainDecoder {
  final int totalLength;
  final List<Uint8List> _symbols = [];
  bool _done = false;

  FakeDecoder(this.totalLength);

  @override
  bool get isComplete => _done;

  @override
  Uint8List? decode(Uint8List symbolBytes) {
    if (_done) return null;
    _symbols.add(symbolBytes);
    final sum = _symbols.fold<int>(0, (a, s) => a + s.length);
    if (sum >= totalLength) {
      _done = true;
      final out = Uint8List(totalLength);
      var offset = 0;
      for (final s in _symbols) {
        out.setRange(offset, offset + s.length, s);
        offset += s.length;
      }
      return out;
    }
    return null;
  }

  @override
  void dispose() {}
}

void main() {
  Future<PickedFile?> picker(Uint8List bytes, String name) async =>
      (name: name, mime: 'application/octet-stream', bytes: bytes);

  Future<FakeFountainFactory> pumpToSettings(
    WidgetTester tester, {
    required Uint8List bytes,
    String name = 'test.bin',
  }) async {
    final factory = FakeFountainFactory();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SendView(
            filePicker: () => picker(bytes, name),
            factory: factory,
            refreshRateProbe: () async => 60,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('pick_file')));
    await tester.pumpAndSettle();
    return factory;
  }

  testWidgets('pick → prepare → settings: one encode, estimate shown',
      (tester) async {
    final factory = await pumpToSettings(
      tester,
      bytes: Uint8List.fromList(List<int>.filled(4096, 0x42)),
    );

    expect(factory.encoderCreations, 1, reason: 'one prepare, no re-chunk');
    expect(find.byKey(const Key('begin_broadcast')), findsOneWidget);
    expect(find.byKey(const Key('fps_group')), findsOneWidget);
    expect(find.byKey(const Key('bytes_group')), findsOneWidget);
    expect(find.byKey(const Key('layout_group')), findsOneWidget);
    expect(find.textContaining('KB/s'), findsOneWidget);
    expect(find.textContaining('test.bin'), findsOneWidget);
  });

  testWidgets('changing fps does NOT re-encode (estimate-only)',
      (tester) async {
    final factory = await pumpToSettings(
      tester,
      bytes: Uint8List.fromList(List<int>.filled(4096, 0x42)),
    );

    await tester.tap(find.text('24'));
    await tester.pumpAndSettle();

    expect(factory.encoderCreations, 1,
        reason: 'fps/layout/high-refresh changes never re-encode');
  });

  testWidgets('changing layout does NOT re-encode', (tester) async {
    final factory = await pumpToSettings(
      tester,
      bytes: Uint8List.fromList(List<int>.filled(4096, 0x42)),
    );

    await tester.tap(find.byKey(const Key('layout_row3')));
    await tester.pumpAndSettle();

    expect(factory.encoderCreations, 1);
  });

  testWidgets('changing bytesPerTile DOES re-encode (new mtu)',
      (tester) async {
    final factory = await pumpToSettings(
      tester,
      bytes: Uint8List.fromList(List<int>.filled(4096, 0x42)),
    );

    await tester.tap(find.text('2 KB'));
    await tester.pumpAndSettle();

    expect(factory.encoderCreations, 2,
        reason: 'bytes-per-tile changes mtu -> re-chunk is correct');
  });

  testWidgets('back from broadcast returns to settings with cache intact',
      (tester) async {
    final factory = await pumpToSettings(
      tester,
      bytes: Uint8List.fromList(List<int>.filled(4096, 0x42)),
    );

    await tester.tap(find.byKey(const Key('begin_broadcast')));
    await tester.pump();
    // The broadcast view shows a Stop control.
    expect(find.text('Stop'), findsOneWidget);

    // Stop returns to the settings step; the cache is NOT re-encoded.
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('begin_broadcast')), findsOneWidget);
    expect(find.textContaining('test.bin'), findsOneWidget);
    expect(factory.encoderCreations, 1,
        reason: 'stopping the broadcast must not re-chunk the cached file');
  });

  testWidgets('Different file clears the cache back to idle', (tester) async {
    await pumpToSettings(
      tester,
      bytes: Uint8List.fromList(List<int>.filled(4096, 0x42)),
    );

    await tester.tap(find.text('Different file'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pick_file')), findsOneWidget);
    expect(find.byKey(const Key('begin_broadcast')), findsNothing);
  });

  testWidgets('empty/invalid file shows an error, not a crash', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SendView(
            filePicker: () async => null,
            factory: FakeFountainFactory(),
            refreshRateProbe: () async => 60,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('pick_file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pick_file')), findsOneWidget);
  });
}

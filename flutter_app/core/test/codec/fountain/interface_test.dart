// Contract tests for the fountain codec interface (Wave 2 T2.4).
//
// Ports the PWA's src/codec/fountain/interface.ts contract into pure Dart.
// The real codec lives behind FFI (Rust facade, T2.3); this file locks the
// interface shapes and the K/MTU math the sender pipeline and receiver
// reassembler depend on. No codec logic is implemented here — contract only.
import 'dart:typed_data';

import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:test/test.dart';

// Trivial implementations that prove the interface shapes compile and are
// instantiable. No codec behavior — that is the FFI facade's job.
class _FakeEncoder implements FountainEncoder {
  _FakeEncoder(this.symbolSize, this.sourceSymbolCount);

  @override
  final int symbolSize;

  @override
  final int sourceSymbolCount;

  @override
  List<EncodedSymbol> encodeSourceSymbols() => const [];

  @override
  List<EncodedSymbol> encodeRepair(int count) =>
      List<EncodedSymbol>.empty(growable: true);

  @override
  void dispose() {} // no-op
}

class _FakeDecoder implements FountainDecoder {
  @override
  Uint8List? decode(Uint8List symbolBytes) => null;

  @override
  bool get isComplete => false;

  @override
  void dispose() {} // no-op
}

class _FakeFactory implements FountainFactory {
  @override
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu) async =>
      _FakeEncoder(mtu, symbolCountForLength(data.length, mtu));

  @override
  Future<FountainDecoder> createDecoder(int totalLength, int mtu) async =>
      _FakeDecoder();
}

void main() {
  group('symbolCountForLength (K formula)', () {
    test('1024 bytes at mtu 1028 is one full symbol', () {
      expect(symbolCountForLength(1024, 1028), 1);
    });

    test('one byte over one symbol pushes K to two (ceil boundary)', () {
      expect(symbolCountForLength(1025, 1028), 2);
    });

    test('64 KiB at mtu 1028 (1024-byte payloads) is 64 symbols', () {
      expect(symbolCountForLength(65536, 1028), 64);
    });

    test('zero-length payload needs zero symbols', () {
      // ceil(0 / payloadSize) == 0, so the formula naturally yields 0: an
      // empty file encodes to no source symbols and the sender skips it.
      expect(symbolCountForLength(0, 1028), 0);
    });

    test('1 MiB at mtu 2052 (2048-byte payloads) is 512 symbols', () {
      expect(symbolCountForLength(1048576, 2052), 512);
    });
  });

  group('interface shapes compile and instantiate', () {
    test('EncodedSymbol carries wire bytes and esi', () {
      final bytes = Uint8List.fromList([1, 2, 3]);

      final symbol = EncodedSymbol(bytes: bytes, esi: 7);

      expect(symbol.bytes, same(bytes));
      expect(symbol.esi, 7);
    });

    test('fake encoder reports symbolSize and sourceSymbolCount', () {
      final encoder = _FakeEncoder(1028, 64);

      expect(encoder.symbolSize, 1028);
      expect(encoder.sourceSymbolCount, 64);
      expect(encoder.encodeSourceSymbols(), isEmpty);
      expect(encoder.encodeRepair(3), isEmpty);
      expect(() => encoder.dispose(), returnsNormally);
    });

    test('fake decoder is incomplete until fed real symbols', () {
      final decoder = _FakeDecoder();

      expect(decoder.isComplete, isFalse);
      expect(decoder.decode(Uint8List(1028)), isNull);
      expect(() => decoder.dispose(), returnsNormally);
    });

    test('fake factory builds both sides asynchronously', () async {
      final factory = _FakeFactory();

      final encoder = await factory.createEncoder(Uint8List(1024), 1028);
      final decoder = await factory.createDecoder(1024, 1028);

      expect(encoder.symbolSize, 1028);
      expect(encoder.sourceSymbolCount, 1);
      expect(decoder.isComplete, isFalse);
    });
  });

  group('assertMtuValid guard (mirrors the Rust crate contract)', () {
    test('mtu below minMtu is rejected', () {
      expect(() => assertMtuValid(63), throwsRangeError);
    });

    test('mtu above maxMtu is rejected', () {
      expect(() => assertMtuValid(65536), throwsRangeError);
    });

    test('minMtu and maxMtu are accepted', () {
      expect(() => assertMtuValid(64), returnsNormally);
      expect(() => assertMtuValid(65535), returnsNormally);
    });
  });
}

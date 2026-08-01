// FRB smoke test — proves the regenerated bridge + facade load the native
// dylib and run the REAL RaptorQ API under plain `dart test` (no Flutter SDK),
// the precondition the full-stack interop test (T4.4) depends on.
import 'dart:typed_data';

import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/rust/api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'ensureRustLib loads the debug dylib and the real RaptorQ API works',
    () async {
      // Given: the bridge is not initialized.
      // When: the lazy facade init runs and the real encoder is built over a
      // small payload.
      await ensureRustLib();
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      const mtu = 1028;
      final encoder = RaptorqEncoder.withDefaults(data: data, mtu: mtu);

      // Then: K and the wire symbol size reflect the payload/mtu, and each
      // source packet is a full mtu-sized wire symbol with SBN == 0.
      expect(encoder.sourceSymbolCount(), greaterThan(BigInt.zero));
      expect(encoder.symbolSize(), BigInt.from(mtu));
      final sourcePackets = encoder.encodeSourcePackets();
      expect(sourcePackets, hasLength(encoder.sourceSymbolCount().toInt()));
      for (final packet in sourcePackets) {
        expect(packet, hasLength(mtu));
        expect(packet[0], 0);
      }

      // A matching decoder reassembles the exact input bytes.
      final decoder = RaptorqDecoder(
        totalLength: BigInt.from(data.length),
        mtu: mtu,
      );
      Uint8List? decoded;
      for (final packet in sourcePackets) {
        decoded = decoder.decode(packet: packet);
        if (decoded != null) {
          break;
        }
      }
      expect(decoded, data);
    },
  );

  test(
    'RustRaptorqFactory round-trips through the facade with ESI extraction',
    () async {
      // Given: a factory over the native bridge.
      final factory = RustRaptorqFactory();

      // When: a small file is encoded, its source symbols are fed to a decoder.
      final data = Uint8List.fromList(List<int>.generate(512, (i) => i % 251));
      const mtu = 1028;
      final encoder = await factory.createEncoder(data, mtu);
      final symbols = encoder.encodeSourceSymbols();

      // Then: esi is the BE24 of bytes 1..3 and runs 0..K-1 in order.
      expect(symbols, isNotEmpty);
      for (var i = 0; i < symbols.length; i++) {
        expect(symbols[i].esi, i);
        expect(symbols[i].bytes, hasLength(mtu));
      }
      expect(encoder.sourceSymbolCount, symbols.length);
      expect(encoder.symbolSize, mtu);

      final decoder = await factory.createDecoder(data.length, mtu);
      Uint8List? decoded;
      for (final symbol in symbols) {
        decoded = decoder.decode(symbol.bytes);
        if (decoded != null) {
          break;
        }
      }
      expect(decoder.isComplete, isTrue);
      expect(decoded, data);
      decoder.dispose();
      encoder.dispose();
    },
  );
}

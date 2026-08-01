/// Receiver FrameBuffer tests — behavior locked before the module exists
/// (TDD RED). Synthetic frames are built with the core wire encoder so the
/// buffer is exercised exactly as the PWA port specifies.
library;

import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:qr_transfer_core/receiver/frames.dart';
import 'package:test/test.dart';

const String sessionA = 'aaaaaaaaaaaaaaaa';
const String sessionB = 'bbbbbbbbbbbbbbbb';

/// Deterministic per-esi payload so symbol order/identity is checkable.
Uint8List payloadFor(int esi) => Uint8List.fromList(
  List<int>.generate(64, (i) => (esi * 13 + i * 7) & 0xff),
);

/// Synthetic DATA wire frame for a fake session.
Uint8List dataFrame(String sessionId, int esi, {int k = 100}) => encodeFrame(
  Frame(
    type: typeData,
    sessionId: sessionId,
    esi: esi,
    k: k,
    totalLen: 0,
    flags: 0,
    payload: payloadFor(esi),
  ),
);

/// Synthetic META wire frame for a fake session.
Uint8List metaFrame(String sessionId, {int k = 100}) => buildMetadataFrame(
  TransferMetadata(
    magic: metaMagic,
    protoVer: protoVersion,
    sessionId: sessionId,
    filename: 'fake.bin',
    mime: 'application/octet-stream',
    totalSize: 0,
    compressedSize: 0,
    compressed: false,
    k: k,
    symbolSize: 1028,
    mtu: 1028,
    fileSHA256: 'a' * 64,
    flags: 0,
  ),
);

void main() {
  group('FrameBuffer', () {
    test('empty buffer exposes null session state and zero counts', () {
      final buffer = FrameBuffer();
      expect(buffer.metadata, isNull);
      expect(buffer.sessionId, isNull);
      expect(buffer.k, isNull);
      expect(buffer.uniqueSymbolCount, 0);
      expect(buffer.totalFramesSeen, 0);
      expect(buffer.droppedCount, 0);
      expect(buffer.symbols(), isEmpty);
      expect(buffer.symbolEsiSet(), isEmpty);
    });

    test('k is exposed from DATA headers before any META frame', () {
      final buffer = FrameBuffer();
      final result = buffer.feed(dataFrame(sessionA, 0, k: 100));
      expect(result.status, FeedStatus.ok);
      expect(buffer.k, 100);
      expect(buffer.metadata, isNull);
    });

    test('in-order feed of k symbols latches session and stores all', () {
      final buffer = FrameBuffer();
      final first = buffer.feed(dataFrame(sessionA, 0));
      expect(first.status, FeedStatus.ok);
      expect(first.isNewSession, isTrue);
      expect(first.frame, isNotNull);

      for (var esi = 1; esi < 100; esi++) {
        final result = buffer.feed(dataFrame(sessionA, esi));
        expect(result.status, FeedStatus.ok);
        expect(result.isNewSession, isFalse);
      }

      expect(buffer.sessionId, sessionA);
      expect(buffer.uniqueSymbolCount, 100);
      expect(buffer.droppedCount, 0);
      expect(buffer.totalFramesSeen, 100);
      final symbols = buffer.symbols();
      expect(symbols.length, 100);
      expect(symbols.first, payloadFor(0));
      expect(symbols.last, payloadFor(99));
      expect(buffer.symbolEsiSet(), {for (var i = 0; i < 100; i++) i});
    });

    test('out-of-order feed stores the same k distinct symbols', () {
      final buffer = FrameBuffer();
      // (i * 37) % 100 is a permutation of 0..99 since gcd(37, 100) == 1.
      for (var i = 0; i < 100; i++) {
        expect(
          buffer.feed(dataFrame(sessionA, (i * 37) % 100)).status,
          FeedStatus.ok,
        );
      }
      expect(buffer.uniqueSymbolCount, 100);
      expect(buffer.droppedCount, 0);
      expect(buffer.totalFramesSeen, 100);
      final symbols = buffer.symbols();
      expect(symbols.length, 100);
      expect(symbols.first, payloadFor(0));
      expect(symbols.last, payloadFor(99));
    });

    test('duplicate esi feeds are counted but not re-stored', () {
      final buffer = FrameBuffer();
      for (var esi = 0; esi < 100; esi++) {
        buffer.feed(dataFrame(sessionA, esi));
      }
      expect(buffer.feed(dataFrame(sessionA, 5)).status, FeedStatus.ok);
      buffer.feed(dataFrame(sessionA, 5));
      buffer.feed(dataFrame(sessionA, 5));
      expect(buffer.uniqueSymbolCount, 100);
      expect(buffer.totalFramesSeen, 103);
      expect(buffer.droppedCount, 0);
    });

    test(
      'corrupt frame yields status error, drops, and leaves buffer intact',
      () {
        final buffer = FrameBuffer();
        buffer.feed(dataFrame(sessionA, 0));
        final corrupted = dataFrame(sessionA, 1);
        corrupted[40] ^= 0xff; // payload byte flip -> CRC32C mismatch
        expect(() => decodeFrame(corrupted), throwsA(isA<ProtocolError>()));
        final result = buffer.feed(corrupted);
        expect(result.status, FeedStatus.error);
        expect(result.frame, isNull);
        expect(result.isNewSession, isFalse);
        expect(buffer.droppedCount, 1);
        expect(buffer.totalFramesSeen, 1);
        expect(buffer.uniqueSymbolCount, 1);
        expect(buffer.symbols(), [payloadFor(0)]);
      },
    );

    test('new sessionId mid-stream resets and latches (isNewSession true)', () {
      final buffer = FrameBuffer();
      for (var esi = 0; esi < 30; esi++) {
        buffer.feed(dataFrame(sessionA, esi));
      }
      final result = buffer.feed(dataFrame(sessionB, 0));
      expect(result.status, FeedStatus.ok);
      expect(result.isNewSession, isTrue);
      expect(buffer.sessionId, sessionB);
      expect(buffer.uniqueSymbolCount, 1);
      expect(buffer.totalFramesSeen, 31);
      expect(buffer.symbols(), [payloadFor(0)]);
    });

    test(
      'META frame parses metadata; different-session META switches session',
      () {
        final buffer = FrameBuffer();
        final resultA = buffer.feed(metaFrame(sessionA));
        expect(resultA.status, FeedStatus.ok);
        expect(resultA.meta, isNotNull);
        expect(resultA.meta!.sessionId, sessionA);
        expect(buffer.metadata, isNotNull);
        expect(buffer.metadata!.sessionId, sessionA);
        expect(buffer.sessionId, sessionA);
        expect(buffer.k, 100);

        buffer.feed(dataFrame(sessionA, 7));
        expect(buffer.uniqueSymbolCount, 1);

        final resultB = buffer.feed(metaFrame(sessionB));
        expect(resultB.status, FeedStatus.ok);
        expect(resultB.isNewSession, isTrue);
        expect(resultB.meta!.sessionId, sessionB);
        expect(buffer.sessionId, sessionB);
        expect(buffer.metadata!.sessionId, sessionB);
        expect(buffer.uniqueSymbolCount, 0); // buffer reset on session switch
      },
    );

    test('META parse failure yields status dropped and drops', () {
      final buffer = FrameBuffer();
      final badJson = encodeFrame(
        Frame(
          type: typeMeta,
          sessionId: sessionA,
          esi: 0,
          k: 100,
          totalLen: 0,
          flags: 0,
          payload: Uint8List.fromList('not json'.codeUnits),
        ),
      );
      final result = buffer.feed(badJson);
      expect(result.status, FeedStatus.dropped);
      expect(result.meta, isNull);
      expect(buffer.droppedCount, 1);
      expect(buffer.totalFramesSeen, 1);
      expect(buffer.uniqueSymbolCount, 0);

      // Header sessionId differs from the metadata payload sessionId.
      final mismatched = encodeFrame(
        Frame(
          type: typeMeta,
          sessionId: sessionB,
          esi: 0,
          k: 100,
          totalLen: 0,
          flags: 0,
          payload: buildMetadataPayload(
            TransferMetadata(
              magic: metaMagic,
              protoVer: protoVersion,
              sessionId: sessionA,
              filename: 'fake.bin',
              mime: 'application/octet-stream',
              totalSize: 0,
              compressedSize: 0,
              compressed: false,
              k: 100,
              symbolSize: 1028,
              mtu: 1028,
              fileSHA256: 'a' * 64,
              flags: 0,
            ),
          ),
        ),
      );
      expect(buffer.feed(mismatched).status, FeedStatus.dropped);
      expect(buffer.droppedCount, 2);
      expect(buffer.metadata, isNull);
    });

    test('reset clears session state but keeps cumulative counters', () {
      final buffer = FrameBuffer();
      buffer.feed(dataFrame(sessionA, 0));
      buffer.feed(dataFrame(sessionA, 1));
      expect(buffer.totalFramesSeen, 2);
      buffer.reset();
      expect(buffer.uniqueSymbolCount, 0);
      expect(buffer.sessionId, isNull);
      expect(buffer.metadata, isNull);
      expect(buffer.k, isNull);
      expect(buffer.totalFramesSeen, 2);
      expect(buffer.droppedCount, 0);
    });

    test('eviction: source symbols never evicted, oldest repair goes first', () {
      final buffer = FrameBuffer(repairBudget: 10);
      for (var esi = 0; esi < 10; esi++) {
        buffer.feed(dataFrame(sessionA, esi, k: 10));
      }
      for (var esi = 10; esi < 35; esi++) {
        buffer.feed(dataFrame(sessionA, esi, k: 10));
      }
      // maxSymbols = k + budget = 20; 35 fed -> 15 oldest repair evicted.
      expect(buffer.uniqueSymbolCount, 20);
      final esis = buffer.symbolEsiSet();
      // Source symbols (esi < k) are never evicted.
      expect({for (var i = 0; i < 10; i++) i}.difference(esis), isEmpty);
      // Oldest repair (10..24) evicted first; newest repair (25..34) retained.
      expect({for (var i = 25; i < 35; i++) i}.difference(esis), isEmpty);
    });

    test('eviction: default budget keeps all symbols below the cap', () {
      final buffer = FrameBuffer();
      for (var esi = 0; esi < 10; esi++) {
        buffer.feed(dataFrame(sessionA, esi, k: 10));
      }
      for (var esi = 10; esi < 35; esi++) {
        buffer.feed(dataFrame(sessionA, esi, k: 10));
      }
      // maxSymbols = k + floor(k * 0.3) + 1000 = 1013; nothing evicted.
      expect(buffer.uniqueSymbolCount, 35);
      final esis = buffer.symbolEsiSet();
      expect({for (var i = 0; i < 10; i++) i}.difference(esis), isEmpty);
      expect({for (var i = 10; i < 35; i++) i}.difference(esis), isEmpty);
    });
  });
}

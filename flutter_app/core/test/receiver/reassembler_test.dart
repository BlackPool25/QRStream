// Receiver reassembler tests (Wave 4 T4.3) — TDD against a FAKE deterministic
// FountainFactory, so core stays FFI-free.
//
// The fake encoder mirrors the landed fountain interface contract: each symbol
// is `mtu` wire bytes = [4-byte esi][payload slice of mtu-4], just like the
// real codec's wire packets (symbolSize == mtu). Repair symbols cycle the
// source offsets, so ANY k distinct esis cover the whole payload. The fake
// decoder parses the esi, places each slice at its offset, and reports the
// recovered file once every byte is covered — order-independent and
// repair-tolerant like the real codec, so a lost source symbol can be
// recovered from a repair symbol.
import 'dart:math';
import 'dart:typed_data';

import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/protocol/sha256.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:qr_transfer_core/receiver/reassembler.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';
import 'package:test/test.dart';

/// Deterministic incompressible bytes (seeded, so tests are repeatable).
Uint8List randomBytes(int length, [int seed = 42]) {
  final rng = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return bytes;
}

/// Wire-serialized symbol header length (the fake codec's per-symbol esi).
const int _esiHeaderLen = 4;

/// Fake encoder: symbol esi carries payload[esi*capacity .. ], padded to a
/// full `symbolSize` wire packet with deterministic filler. Repair symbols
/// (esi >= k) cycle the source offsets via (esi % k), so any k distinct esis
/// reconstruct the payload — the fountain property this fake exists to give.
class _FakeEncoder implements FountainEncoder {
  _FakeEncoder({
    required this.symbolSize,
    required this.sourceSymbolCount,
    required this.payload,
  });

  @override
  final int symbolSize;

  @override
  final int sourceSymbolCount;

  final Uint8List payload;

  int get _capacity => symbolSize - _esiHeaderLen;

  @override
  List<EncodedSymbol> encodeSourceSymbols() => _symbols(0, sourceSymbolCount);

  @override
  List<EncodedSymbol> encodeRepair(int count) => <EncodedSymbol>[
    ..._symbols(0, sourceSymbolCount),
    ..._symbols(sourceSymbolCount, count),
  ];

  List<EncodedSymbol> _symbols(int esiStart, int n) =>
      List.generate(n, (i) => _symbolAt(esiStart + i));

  EncodedSymbol _symbolAt(int esi) {
    final slice = _sliceAt(esi % sourceSymbolCount);
    final wire = Uint8List(symbolSize);
    ByteData.sublistView(wire).setUint32(0, esi);
    wire.setRange(_esiHeaderLen, symbolSize, slice);
    return EncodedSymbol(bytes: wire, esi: esi);
  }

  Uint8List _sliceAt(int index) {
    final offset = index * _capacity;
    final slice = Uint8List(_capacity);
    for (var j = 0; j < _capacity; j++) {
      final src = offset + j;
      slice[j] = src < payload.length ? payload[src] : (index * 31 + j) & 0xff;
    }
    return slice;
  }

  @override
  void dispose() {}
}

/// Fake decoder: parses the esi header, places each slice at its offset, and
/// returns the recovered file once every byte of [totalLength] is covered.
class _FakeDecoder implements FountainDecoder {
  _FakeDecoder(this.totalLength, {this.throwOnDecode = false});

  final int totalLength;
  final bool throwOnDecode;

  late final Uint8List _buffer = Uint8List(totalLength);
  late final List<bool> _covered = List.filled(totalLength, false);
  int _coveredCount = 0;
  bool _complete = false;

  @override
  Uint8List? decode(Uint8List symbolBytes) {
    if (throwOnDecode) {
      throw StateError('decode failed');
    }
    if (_complete) {
      return Uint8List.fromList(_buffer);
    }
    final esi = ByteData.sublistView(
      symbolBytes,
      0,
      _esiHeaderLen,
    ).getUint32(0);
    final capacity = symbolBytes.length - _esiHeaderLen;
    final k = (totalLength / capacity).ceil();
    final offset = (esi % k) * capacity;
    for (var j = 0; j < capacity; j++) {
      final pos = offset + j;
      if (pos >= totalLength) break;
      if (!_covered[pos]) {
        _covered[pos] = true;
        _buffer[pos] = symbolBytes[_esiHeaderLen + j];
        _coveredCount++;
      }
    }
    _complete = _coveredCount >= totalLength;
    if (!_complete) return null;
    return Uint8List.fromList(_buffer);
  }

  @override
  bool get isComplete => _complete;

  @override
  void dispose() {}
}

/// Deterministic fake factory with knobs for the reassembler's error paths.
class _FakeFactory implements FountainFactory {
  _FakeFactory({this.failDecoderCreation = false, this.throwOnDecode = false});

  final bool failDecoderCreation;
  final bool throwOnDecode;

  /// Every decoder built, so tests can assert the one-shot/reset semantics.
  final List<_FakeDecoder> createdDecoders = <_FakeDecoder>[];

  @override
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu) async =>
      _FakeEncoder(
        symbolSize: mtu,
        sourceSymbolCount: symbolCountForLength(data.length, mtu),
        payload: data,
      );

  @override
  Future<FountainDecoder> createDecoder(int totalLength, int mtu) async {
    if (failDecoderCreation) {
      throw StateError('decoder creation failed');
    }
    final decoder = _FakeDecoder(totalLength, throwOnDecode: throwOnDecode);
    createdDecoders.add(decoder);
    return decoder;
  }
}

/// Parse the single META frame the pipeline emitted.
TransferMetadata metadataOf(PreparedTransfer prepared) =>
    parseMetadataFrame(prepared.metaFrames.single);

/// Extract every DATA frame's symbol payload, in esi order.
List<Uint8List> symbolPayloads(PreparedTransfer prepared) =>
    prepared.dataFrames.map((f) => decodeFrame(f).payload).toList();

Matcher reassemblyError(ReassemblyErrorCode code) =>
    isA<ReassemblyError>().having((e) => e.code, 'code', code);

void main() {
  group('integrity gate (happy path)', () {
    test(
      'full transfer reassembles to byte-identical, verified bytes',
      () async {
        final file = randomBytes(5000);
        final factory = _FakeFactory();
        final prepared = await prepareTransfer(
          file: file,
          filename: 'sample.bin',
          mime: 'application/octet-stream',
          factory: factory,
        );
        final meta = metadataOf(prepared);

        final reassembler = Reassembler(
          mtu: prepared.info.mtu,
          factory: factory,
        );
        await reassembler.start(meta, symbolPayloads(prepared), <int>{});

        expect(reassembler.isComplete, isTrue);
        final result = await reassembler.finish();
        expect(result.bytes, equals(file));
        expect(result.verified, isTrue);
        expect(result.sha256, sha256Hex(file));
        expect(result.sha256, meta.fileSHA256);
        expect(result.mime, 'application/octet-stream');
        expect(result.filename, 'sample.bin');
      },
    );

    test(
      'compressed transfer inflates back to the byte-identical original',
      () async {
        final file = Uint8List.fromList(List.filled(10000, 0x41));
        final factory = _FakeFactory();
        final prepared = await prepareTransfer(
          file: file,
          filename: 'a.txt',
          mime: 'text/plain',
          factory: factory,
        );
        expect(prepared.info.compressed, isTrue);
        final meta = metadataOf(prepared);

        final reassembler = Reassembler(
          mtu: prepared.info.mtu,
          factory: factory,
        );
        await reassembler.start(meta, symbolPayloads(prepared), <int>{});

        final result = await reassembler.finish();
        expect(result.bytes, equals(file));
        expect(result.verified, isTrue);
        expect(result.sha256, sha256Hex(file));
      },
    );
  });

  group('hash-mismatch integrity gate', () {
    test(
      'tampered symbol → hashMismatch; never verified with wrong bytes',
      () async {
        final file = randomBytes(5000);
        final factory = _FakeFactory();
        final prepared = await prepareTransfer(
          file: file,
          filename: 'sample.bin',
          mime: 'application/octet-stream',
          factory: factory,
        );
        final meta = metadataOf(prepared);

        final symbols = symbolPayloads(prepared);
        // Flip one bit of the first payload byte (past the esi header).
        symbols[0][_esiHeaderLen] ^= 0xff;

        final reassembler = Reassembler(
          mtu: prepared.info.mtu,
          factory: factory,
        );
        await reassembler.start(meta, symbols, <int>{});

        await expectLater(
          reassembler.finish(),
          throwsA(reassemblyError(ReassemblyErrorCode.hashMismatch)),
        );
      },
    );

    test('metadata with a wrong fileSHA256 → hashMismatch', () async {
      final file = randomBytes(3000);
      final factory = _FakeFactory();
      final prepared = await prepareTransfer(
        file: file,
        filename: 'f.bin',
        mime: 'application/octet-stream',
        factory: factory,
      );
      final good = metadataOf(prepared);
      final wrongSha = TransferMetadata(
        magic: good.magic,
        protoVer: good.protoVer,
        sessionId: good.sessionId,
        filename: good.filename,
        mime: good.mime,
        totalSize: good.totalSize,
        compressedSize: good.compressedSize,
        compressed: good.compressed,
        k: good.k,
        symbolSize: good.symbolSize,
        mtu: good.mtu,
        fileSHA256: sha256Hex(randomBytes(64, 7)),
        flags: good.flags,
      );

      final reassembler = Reassembler(mtu: prepared.info.mtu, factory: factory);
      await reassembler.start(wrongSha, symbolPayloads(prepared), <int>{});

      await expectLater(
        reassembler.finish(),
        throwsA(reassemblyError(ReassemblyErrorCode.hashMismatch)),
      );
    });
  });

  group('completion states', () {
    test('fewer than k symbols → finish() throws notComplete', () async {
      final file = randomBytes(5000); // k = 5 at mtu 1028
      final factory = _FakeFactory();
      final prepared = await prepareTransfer(
        file: file,
        filename: 'f.bin',
        mime: 'application/octet-stream',
        factory: factory,
      );
      final meta = metadataOf(prepared);

      final reassembler = Reassembler(mtu: prepared.info.mtu, factory: factory);
      await reassembler.start(
        meta,
        symbolPayloads(prepared).take(prepared.info.k - 1).toList(),
        <int>{},
      );

      expect(reassembler.isComplete, isFalse);
      await expectLater(
        reassembler.finish(),
        throwsA(reassemblyError(ReassemblyErrorCode.notComplete)),
      );
    });

    test(
      'zero-length transfer short-circuits to an empty verified result',
      () async {
        final reassembler = Reassembler(mtu: 1028, factory: _FakeFactory());
        final emptySha = sha256Hex(Uint8List(0));
        final meta = TransferMetadata(
          magic: metaMagic,
          protoVer: protoVersion,
          sessionId: '0123456789abcdef',
          filename: 'empty.bin',
          mime: 'application/octet-stream',
          totalSize: 0,
          compressedSize: 0,
          compressed: false,
          k: 0,
          symbolSize: 1024,
          mtu: 1028,
          fileSHA256: emptySha,
          flags: 0,
        );

        await reassembler.start(meta, const <Uint8List>[], <int>{});

        expect(reassembler.isComplete, isTrue);
        final result = await reassembler.finish();
        expect(result.bytes, isEmpty);
        expect(result.verified, isTrue);
        expect(result.sha256, emptySha);
        expect(result.filename, 'empty.bin');
      },
    );
  });

  group('decode failures', () {
    test('decoder creation failure → decodeFailed from start()', () async {
      final reassembler = Reassembler(
        mtu: 1028,
        factory: _FakeFactory(failDecoderCreation: true),
      );
      final meta = TransferMetadata(
        magic: metaMagic,
        protoVer: protoVersion,
        sessionId: '0123456789abcdef',
        filename: 'f.bin',
        mime: 'application/octet-stream',
        totalSize: 100,
        compressedSize: 0,
        compressed: false,
        k: 1,
        symbolSize: 1024,
        mtu: 1028,
        fileSHA256: sha256Hex(randomBytes(100)),
        flags: 0,
      );

      await expectLater(
        reassembler.start(meta, const <Uint8List>[], <int>{}),
        throwsA(reassemblyError(ReassemblyErrorCode.decodeFailed)),
      );
    });

    test(
      'decoder that throws while feeding → finish() reports decodeFailed',
      () async {
        final file = randomBytes(2000);
        final factory = _FakeFactory();
        final prepared = await prepareTransfer(
          file: file,
          filename: 'f.bin',
          mime: 'application/octet-stream',
          factory: factory,
        );
        final meta = metadataOf(prepared);

        final reassembler = Reassembler(
          mtu: prepared.info.mtu,
          factory: _FakeFactory(throwOnDecode: true),
        );
        await reassembler.start(meta, symbolPayloads(prepared), <int>{});

        await expectLater(
          reassembler.finish(),
          throwsA(reassemblyError(ReassemblyErrorCode.decodeFailed)),
        );
      },
    );

    test(
      'start called twice without reset → decodeFailed (one-shot)',
      () async {
        final file = randomBytes(2000);
        final factory = _FakeFactory();
        final prepared = await prepareTransfer(
          file: file,
          filename: 'f.bin',
          mime: 'application/octet-stream',
          factory: factory,
        );
        final meta = metadataOf(prepared);

        final reassembler = Reassembler(
          mtu: prepared.info.mtu,
          factory: factory,
        );
        await reassembler.start(meta, symbolPayloads(prepared), <int>{});

        await expectLater(
          reassembler.start(meta, const <Uint8List>[], <int>{}),
          throwsA(reassemblyError(ReassemblyErrorCode.decodeFailed)),
        );
      },
    );
  });

  group('one-shot lifecycle', () {
    test(
      'reset() frees the decoder so the next transfer starts fresh',
      () async {
        final factory = _FakeFactory();
        final file = randomBytes(3000);
        final prepared = await prepareTransfer(
          file: file,
          filename: 'f.bin',
          mime: 'application/octet-stream',
          factory: factory,
        );
        final meta = metadataOf(prepared);

        final reassembler = Reassembler(
          mtu: prepared.info.mtu,
          factory: factory,
        );
        await reassembler.start(meta, symbolPayloads(prepared), <int>{});
        final first = await reassembler.finish();
        expect(first.verified, isTrue);
        expect(factory.createdDecoders, hasLength(1));

        reassembler.reset();
        expect(reassembler.isComplete, isFalse);

        final file2 = randomBytes(2000, 7);
        final second = await prepareTransfer(
          file: file2,
          filename: 'g.bin',
          mime: 'application/octet-stream',
          factory: factory,
        );
        await reassembler.start(
          metadataOf(second),
          symbolPayloads(second),
          <int>{},
        );

        expect(factory.createdDecoders, hasLength(2));
        final result = await reassembler.finish();
        expect(result.verified, isTrue);
        expect(result.bytes, equals(file2));
      },
    );
  });

  group('fountain property through the fake', () {
    test('lost source symbols are recovered from repair symbols', () async {
      final file = randomBytes(5000); // k = 5 at mtu 1028
      final factory = _FakeFactory();
      final prepared = await prepareTransfer(
        file: file,
        filename: 'f.bin',
        mime: 'application/octet-stream',
        factory: factory,
      );
      final meta = metadataOf(prepared);

      // Feed only 80% of the source symbols (drop the last, esi 4).
      final lost = symbolPayloads(prepared).take(prepared.info.k - 1).toList();
      final reassembler = Reassembler(mtu: prepared.info.mtu, factory: factory);
      await reassembler.start(meta, lost, <int>{});

      expect(reassembler.isComplete, isFalse);

      // Repair symbols cycle the missing source offsets, so feeding them
      // fills the coverage hole and the file completes.
      final repairs = repairFrames(
        prepared,
        prepared.info.k,
      ).map((frameBytes) => decodeFrame(frameBytes).payload).toList();
      reassembler.feedMore(repairs, <int>{});

      expect(reassembler.isComplete, isTrue);
      final result = await reassembler.finish();
      expect(result.bytes, equals(file));
      expect(result.verified, isTrue);
    });
  });
}

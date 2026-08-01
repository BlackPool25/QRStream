// Sender pipeline tests (Wave 3 T3.3) — TDD against a FAKE deterministic
// FountainFactory, so core stays FFI-free.
//
// The fake encoder mirrors the landed fountain interface contract: source
// symbols are deterministic slices of the payload (esi 0..k-1), and
// encodeRepair returns the K source symbols followed by `count` repair
// symbols (esi k..k+count-1). The fake decoder concatenates fed symbols and
// truncates to the transfer's total length, like the real codec.
import 'dart:math';
import 'dart:typed_data';

import 'package:qr_transfer_core/codec/deflate.dart';
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/protocol/sha256.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
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

/// Deterministic fake encoder: symbol i carries payload[i*symbolSize, ...]
/// zero-ish padded to symbolSize; repairs are fresh symbols esi >= k.
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

  @override
  List<EncodedSymbol> encodeSourceSymbols() => _symbols(0, sourceSymbolCount);

  @override
  List<EncodedSymbol> encodeRepair(int count) => <EncodedSymbol>[
    ..._symbols(0, sourceSymbolCount),
    ..._symbols(sourceSymbolCount, count),
  ];

  List<EncodedSymbol> _symbols(int esiStart, int n) => List.generate(n, (i) {
    final esi = esiStart + i;
    final offset = esi * symbolSize;
    final bytes = Uint8List(symbolSize);
    for (var j = 0; j < symbolSize; j++) {
      final src = offset + j;
      bytes[j] = src < payload.length ? payload[src] : (esi * 31 + j) & 0xff;
    }
    return EncodedSymbol(bytes: bytes, esi: esi);
  });

  @override
  void dispose() {}
}

/// Fake decoder: concatenates fed symbols, returns the truncation to
/// [totalLength] once enough bytes have arrived.
class _FakeDecoder implements FountainDecoder {
  _FakeDecoder(this.totalLength);

  final int totalLength;
  final List<int> _buffer = <int>[];
  bool _complete = false;

  @override
  Uint8List? decode(Uint8List symbolBytes) {
    if (!_complete) {
      _buffer.addAll(symbolBytes);
      _complete = _buffer.length >= totalLength;
    }
    if (!_complete) return null;
    return Uint8List.fromList(_buffer.take(totalLength).toList());
  }

  @override
  bool get isComplete => _complete;

  @override
  void dispose() {}
}

/// Deterministic fake factory with optional knobs to probe the pipeline's
/// error paths: [symbolSizeOverride] (FRAME_TOO_LARGE) and
/// [forceSourceSymbolCount] (K_SANITY_FAILED).
class _FakeFactory implements FountainFactory {
  _FakeFactory({this.symbolSizeOverride, this.forceSourceSymbolCount});

  final int? symbolSizeOverride;
  final int? forceSourceSymbolCount;

  @override
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu) async {
    final symbolSize = symbolSizeOverride ?? mtu - 4;
    final k = forceSourceSymbolCount ?? symbolCountForLength(data.length, mtu);
    return _FakeEncoder(
      symbolSize: symbolSize,
      sourceSymbolCount: k,
      payload: data,
    );
  }

  @override
  Future<FountainDecoder> createDecoder(int totalLength, int mtu) async =>
      _FakeDecoder(totalLength);
}

Matcher pipelineError(PipelineErrorCode code) =>
    isA<PipelineError>().having((e) => e.code, 'code', code);

void main() {
  group('default settings (incompressible input)', () {
    final file = randomBytes(5000);

    test(
      'TransferInfo carries the PWA defaults and derived codec fields',
      () async {
        final prepared = await prepareTransfer(
          file: file,
          filename: 'sample.bin',
          mime: 'application/octet-stream',
          factory: _FakeFactory(),
        );
        final info = prepared.info;

        expect(info.settings.bytesPerTile, BytesPerTileId.oneK);
        expect(info.settings.layout, LayoutId.grid4);
        expect(info.settings.targetFps, 15);
        expect(info.settings.highRefresh, isFalse);
        expect(info.bytesPerTile, BytesPerTileId.oneK);
        expect(info.mtu, 1028);
        expect(info.symbolSize, 1024);
        expect(info.k, (5000 / 1024).ceil());
        expect(info.totalSize, 5000);
        expect(info.compressedSize, 5000);
        expect(info.compressed, isFalse);
        expect(info.fileSHA256, sha256Hex(file));
        expect(info.sessionId, matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(prepared.metaFrames, hasLength(1));
      },
    );

    test('one DATA frame per source symbol with correct wire fields', () async {
      final prepared = await prepareTransfer(
        file: file,
        filename: 'sample.bin',
        mime: 'application/octet-stream',
        factory: _FakeFactory(),
      );
      final info = prepared.info;

      expect(prepared.dataFrames, hasLength(info.k));
      for (var i = 0; i < prepared.dataFrames.length; i++) {
        final frame = decodeFrame(prepared.dataFrames[i]);
        expect(frame.type, typeData);
        expect(frame.sessionId, info.sessionId);
        expect(frame.esi, i);
        expect(frame.k, info.k);
        expect(frame.totalLen, info.compressedSize);
        expect(frame.flags, 0);
        expect(frame.payload.length, info.symbolSize);
      }
    });

    test('META frame parses to all fields matching TransferInfo', () async {
      final prepared = await prepareTransfer(
        file: file,
        filename: 'sample.bin',
        mime: 'application/octet-stream',
        factory: _FakeFactory(),
      );
      final info = prepared.info;

      final meta = parseMetadataFrame(prepared.metaFrames.single);
      expect(meta.magic, metaMagic);
      expect(meta.protoVer, protoVersion);
      expect(meta.sessionId, info.sessionId);
      expect(meta.filename, 'sample.bin');
      expect(meta.mime, 'application/octet-stream');
      expect(meta.totalSize, info.totalSize);
      expect(meta.compressed, isFalse);
      expect(meta.k, info.k);
      expect(meta.symbolSize, info.symbolSize);
      expect(meta.mtu, info.mtu);
      expect(meta.fileSHA256, info.fileSHA256);
      expect(meta.flags, 0);
    });
  });

  group('metadata compressedSize quirk', () {
    test(
      'pins META compressedSize to 0 while DATA frames carry the true length',
      () async {
        final file = randomBytes(3000);
        final prepared = await prepareTransfer(
          file: file,
          filename: 'u.bin',
          mime: 'application/octet-stream',
          factory: _FakeFactory(),
        );
        final info = prepared.info;

        // Uncompressed: the metadata document and the META wire frame's totalLen
        // both report 0, while every DATA frame carries the true wire length.
        final meta = parseMetadataFrame(prepared.metaFrames.single);
        expect(meta.compressedSize, 0);
        expect(decodeFrame(prepared.metaFrames.single).totalLen, 0);
        expect(
          decodeFrame(prepared.dataFrames.first).totalLen,
          info.compressedSize,
        );
      },
    );
  });

  group('compressible input', () {
    test('compresses and round-trips to the original file', () async {
      final file = Uint8List.fromList(List.filled(10000, 0x41)); // 10000 'A'
      final prepared = await prepareTransfer(
        file: file,
        filename: 'a.txt',
        mime: 'text/plain',
        factory: _FakeFactory(),
      );
      final info = prepared.info;

      expect(info.compressed, isTrue);
      expect(info.compressedSize, lessThan(info.totalSize));

      final decoder = await _FakeFactory().createDecoder(
        info.compressedSize,
        info.mtu,
      );
      Uint8List? recovered;
      for (final frameBytes in prepared.dataFrames) {
        final frame = decodeFrame(frameBytes);
        expect(frame.flags, flagCompressed);
        recovered = decoder.decode(frame.payload);
      }
      expect(recovered, isNotNull);
      expect(
        decompress(
          CompressedResult(data: recovered!, compressed: info.compressed),
        ),
        file,
      );
    });
  });

  group('errors', () {
    test('empty file → emptyFile', () async {
      await expectLater(
        prepareTransfer(
          file: Uint8List(0),
          filename: 'e.bin',
          mime: 'application/octet-stream',
          factory: _FakeFactory(),
        ),
        throwsA(pipelineError(PipelineErrorCode.emptyFile)),
      );
    });

    test('file over the wire totalLen limit → tooLarge', () async {
      final big = randomBytes(maxTotalLen + 1, 7);
      await expectLater(
        prepareTransfer(
          file: big,
          filename: 'big.bin',
          mime: 'application/octet-stream',
          factory: _FakeFactory(),
        ),
        throwsA(pipelineError(PipelineErrorCode.tooLarge)),
      );
    });

    test(
      'encoder symbol size beyond the frame budget → frameTooLarge',
      () async {
        final factory = _FakeFactory(symbolSizeOverride: 2000);
        await expectLater(
          prepareTransfer(
            file: randomBytes(100),
            filename: 'f.bin',
            mime: 'application/octet-stream',
            factory: factory,
          ),
          throwsA(pipelineError(PipelineErrorCode.frameTooLarge)),
        );
      },
    );

    test('encoder k too small for the payload → kSanityFailed', () async {
      final factory = _FakeFactory(forceSourceSymbolCount: 1);
      await expectLater(
        prepareTransfer(
          file: randomBytes(10000),
          filename: 'f.bin',
          mime: 'application/octet-stream',
          factory: factory,
        ),
        throwsA(pipelineError(PipelineErrorCode.kSanityFailed)),
      );
    });

    test('invalid settings → ArgumentError propagates', () async {
      const bad = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 99,
        highRefresh: false,
      );
      await expectLater(
        prepareTransfer(
          file: randomBytes(100),
          filename: 'f.bin',
          mime: 'application/octet-stream',
          settings: bad,
          factory: _FakeFactory(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('repair frames', () {
    test('repairFrames emits count DATA frames with esi >= k', () async {
      final prepared = await prepareTransfer(
        file: randomBytes(3000),
        filename: 'f.bin',
        mime: 'application/octet-stream',
        factory: _FakeFactory(),
      );
      final info = prepared.info;

      final repair = repairFrames(prepared, 3);
      expect(repair, hasLength(3));
      for (final frameBytes in repair) {
        final frame = decodeFrame(frameBytes);
        expect(frame.type, typeData);
        expect(frame.sessionId, info.sessionId);
        expect(frame.esi, greaterThanOrEqualTo(info.k));
        expect(frame.k, info.k);
        expect(frame.totalLen, info.compressedSize);
        expect(frame.payload.length, info.symbolSize);
      }
    });

    test('negative repair count → badRepairCount', () async {
      final prepared = await prepareTransfer(
        file: randomBytes(100),
        filename: 'f.bin',
        mime: 'application/octet-stream',
        factory: _FakeFactory(),
      );
      expect(
        () => repairFrames(prepared, -1),
        throwsA(pipelineError(PipelineErrorCode.badRepairCount)),
      );
    });
  });

  group('determinism', () {
    test(
      'same input twice → identical symbol payloads (deterministic fake)',
      () async {
        final file = randomBytes(4000);
        final first = await prepareTransfer(
          file: file,
          filename: 'a.bin',
          mime: 'application/octet-stream',
          factory: _FakeFactory(),
        );
        final second = await prepareTransfer(
          file: file,
          filename: 'a.bin',
          mime: 'application/octet-stream',
          factory: _FakeFactory(),
        );

        // Each send session gets a fresh sessionId, but the fake factory is
        // deterministic, so the DATA symbol payloads are byte-identical.
        expect(first.info.sessionId, isNot(second.info.sessionId));
        expect(second.dataFrames, hasLength(first.dataFrames.length));
        for (var i = 0; i < first.dataFrames.length; i++) {
          final f1 = decodeFrame(first.dataFrames[i]);
          final f2 = decodeFrame(second.dataFrames[i]);
          expect(f1.esi, i);
          expect(f2.esi, i);
          expect(f2.payload, f1.payload);
          expect(f2.k, f1.k);
          expect(f2.totalLen, f1.totalLen);
          expect(f2.flags, f1.flags);
        }
      },
    );
  });
}

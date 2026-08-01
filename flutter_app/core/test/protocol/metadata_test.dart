import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:test/test.dart';

/// The 13 metadata payload keys in their canonical wire order.
const List<String> expectedKeys = [
  'magic',
  'protoVer',
  'sessionId',
  'filename',
  'mime',
  'totalSize',
  'compressedSize',
  'compressed',
  'k',
  'symbolSize',
  'mtu',
  'fileSHA256',
  'flags',
];

/// Metadata of the committed random-64k fixture (manifest.json values).
TransferMetadata random64kMeta() => TransferMetadata(
  magic: metaMagic,
  protoVer: protoVersion,
  sessionId: '956f24d160351a09',
  filename: 'random-64k.bin',
  mime: 'application/octet-stream',
  totalSize: 65536,
  compressedSize: 0,
  compressed: false,
  k: 64,
  symbolSize: 1028,
  mtu: 1028,
  fileSHA256:
      '28b8086c08e3cfef2de3f75bb2ac24bf6b691722f9aff9a75b534da5d0bf3f85',
  flags: 0,
);

String bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Build a wire frame with an arbitrary JSON payload (for error tests).
Uint8List frameWithPayload({
  int type = typeMeta,
  required String sessionId,
  required String payload,
  int k = 64,
  int totalLen = 0,
}) => encodeFrame(
  Frame(
    type: type,
    sessionId: sessionId,
    esi: 0,
    k: k,
    totalLen: totalLen,
    flags: 0,
    payload: utf8.encode(payload),
  ),
);

void main() {
  group('golden (pinned against the PWA)', () {
    test('payload JSON has exactly the 13 keys in canonical order', () {
      final frame = decodeFrame(buildMetadataFrame(random64kMeta()));
      final json =
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      expect(json.keys.toList(), expectedKeys);
    });

    test('full META frame hex matches the PWA buildMetadataFrame output', () {
      // Computed with the PWA's buildMetadataFrame for the same input
      // (src/protocol/metadata.ts, random-64k manifest values) — byte-identical
      // to the committed fixture test/fixtures/random-64k/meta.frame.
      const pinnedHex =
          '515244460102956f24d160351a0900000000400000003501000000000000'
          '7b226d61676963223a22515244462d4d455441222c2270726f746f56657222'
          '3a312c2273657373696f6e4964223a22393536663234643136303335316130'
          '39222c2266696c656e616d65223a2272616e646f6d2d36346b2e62696e222c'
          '226d696d65223a226170706c69636174696f6e2f6f637465742d7374726561'
          '6d222c22746f74616c53697a65223a36353533362c22636f6d707265737365'
          '6453697a65223a302c22636f6d70726573736564223a66616c73652c226b22'
          '3a36342c2273796d626f6c53697a65223a313032382c226d7475223a313032'
          '382c2266696c65534841323536223a22323862383038366330386533636665'
          '66326465336637356262326163323462663662363931373232663961666639'
          '613735623533346461356430626633663835222c22666c616773223a307d'
          'ca4f3955';
      expect(bytesToHex(buildMetadataFrame(random64kMeta())), pinnedHex);
    });
  });

  group('fixture random-64k/meta.frame', () {
    test('parseMetadataFrame yields all manifest fields', () {
      final meta = parseMetadataFrame(
        File('test/fixtures/random-64k/meta.frame').readAsBytesSync(),
      );
      expect(meta.magic, metaMagic);
      expect(meta.protoVer, 1);
      expect(meta.sessionId, '956f24d160351a09');
      expect(meta.filename, 'random-64k.bin');
      expect(meta.mime, 'application/octet-stream');
      expect(meta.totalSize, 65536);
      expect(meta.compressedSize, 0);
      expect(meta.compressed, isFalse);
      expect(meta.k, 64);
      expect(meta.mtu, 1028);
      expect(meta.symbolSize, 1028);
      expect(
        meta.fileSHA256,
        '28b8086c08e3cfef2de3f75bb2ac24bf6b691722f9aff9a75b534da5d0bf3f85',
      );
      expect(meta.flags, 0);
    });
  });

  group('round-trip', () {
    test('build → parse reproduces all fields (uncompressed)', () {
      final meta = random64kMeta();
      expect(parseMetadataFrame(buildMetadataFrame(meta)), meta);
    });

    test('build → parse reproduces all fields (compressed)', () {
      final meta = TransferMetadata(
        magic: metaMagic,
        protoVer: protoVersion,
        sessionId: 'abcd1234abcd1234',
        filename: 'big.gz',
        mime: 'application/gzip',
        totalSize: 1000000,
        compressedSize: 4321,
        compressed: true,
        k: 1024,
        symbolSize: 1028,
        mtu: 1028,
        fileSHA256: 'a' * 64,
        flags: 1,
      );
      expect(parseMetadataFrame(buildMetadataFrame(meta)), meta);
    });
  });

  group('parse errors', () {
    Matcher metadataError(MetadataErrorCode code) =>
        isA<MetadataError>().having((e) => e.code, 'code', code);

    test('non-JSON payload → badJson', () {
      final bytes = frameWithPayload(
        sessionId: '956f24d160351a09',
        payload: 'this is not json {',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.badJson)),
      );
    });

    test('JSON array payload (not an object) → badJson', () {
      final bytes = frameWithPayload(
        sessionId: '956f24d160351a09',
        payload: '[1,2,3]',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.badJson)),
      );
    });

    test('wrong-typed key → badKey', () {
      final bytes = frameWithPayload(
        sessionId: '956f24d160351a09',
        payload: '{"magic":"QRDF-META","protoVer":"1"}',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.badKey)),
      );
    });

    test('missing key → badKey', () {
      final bytes = frameWithPayload(
        sessionId: '956f24d160351a09',
        payload: '{"magic":"QRDF-META"}',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.badKey)),
      );
    });

    test('bad magic → badValue', () {
      final bytes = frameWithPayload(
        sessionId: '956f24d160351a09',
        payload: '{"magic":"NOPE","protoVer":1}',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.badValue)),
      );
    });

    test('compressed=true with compressedSize=0 → badValue', () {
      final bytes = frameWithPayload(
        sessionId: '956f24d160351a09',
        payload:
            '{"magic":"QRDF-META","protoVer":1,"sessionId":"956f24d160351a09",'
            '"filename":"x.bin","mime":"application/octet-stream","totalSize":100,'
            '"compressedSize":0,"compressed":true,"k":1,"symbolSize":1028,"mtu":1028,'
            '"fileSHA256":"${'a' * 64}","flags":1}',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.badValue)),
      );
    });

    test('header/payload sessionId mismatch → sessionIdMismatch', () {
      final bytes = frameWithPayload(
        sessionId: 'aaaaaaaaaaaaaaaa',
        payload:
            '{"magic":"QRDF-META","protoVer":1,'
            '"sessionId":"956f24d160351a09","filename":"x.bin",'
            '"mime":"application/octet-stream","totalSize":100,'
            '"compressedSize":0,"compressed":false,"k":1,"symbolSize":1028,'
            '"mtu":1028,"fileSHA256":"${'a' * 64}","flags":0}',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.sessionIdMismatch)),
      );
    });

    test('DATA frame → notMeta', () {
      final bytes = frameWithPayload(
        type: typeData,
        sessionId: '956f24d160351a09',
        payload:
            '{"magic":"QRDF-META","protoVer":1,'
            '"sessionId":"956f24d160351a09","filename":"x.bin",'
            '"mime":"application/octet-stream","totalSize":100,'
            '"compressedSize":0,"compressed":false,"k":1,"symbolSize":1028,'
            '"mtu":1028,"fileSHA256":"${'a' * 64}","flags":0}',
      );
      expect(
        () => parseMetadataFrame(bytes),
        throwsA(metadataError(MetadataErrorCode.notMeta)),
      );
    });
  });
}

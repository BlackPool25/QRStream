import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:test/test.dart';

void expectProfile(
  BytesPerTileProfile profile, {
  required int version,
  required int symbolSize,
  required int mtu,
  required int chunkSize,
  required int frameBudget,
}) {
  expect(profile.version, version, reason: 'version');
  expect(profile.symbolSize, symbolSize, reason: 'symbolSize');
  expect(profile.mtu, mtu, reason: 'mtu');
  expect(profile.chunkSize, chunkSize, reason: 'chunkSize');
  expect(profile.frameBudget, frameBudget, reason: 'frameBudget');
}

void main() {
  group('scalar constants', () {
    test('magicQrdf is the QRDF magic bytes', () {
      expect(magicQrdf, [0x51, 0x52, 0x44, 0x46]);
    });

    test('protoVersion is 1', () {
      expect(protoVersion, 1);
    });

    test('typeData is 0x01', () {
      expect(typeData, 0x01);
    });

    test('typeMeta is 0x02', () {
      expect(typeMeta, 0x02);
    });

    test('headerLen is 30', () {
      expect(headerLen, 30);
    });

    test('crcLen is 4', () {
      expect(crcLen, 4);
    });

    test('flagCompressed is 0x01', () {
      expect(flagCompressed, 0x01);
    });

    test('metadataRebroadcastEvery is 32', () {
      expect(metadataRebroadcastEvery, 32);
    });

    test('sessionIdLen is 8', () {
      expect(sessionIdLen, 8);
    });

    test('maxTotalLen is 0xffffff', () {
      expect(maxTotalLen, 0xffffff);
    });

    test('metaMagic is QRDF-META', () {
      expect(metaMagic, 'QRDF-META');
    });
  });

  group('BytesPerTileId', () {
    test('wire ids match the TS string union', () {
      expect(BytesPerTileId.oneK.id, '1k');
      expect(BytesPerTileId.twoK.id, '2k');
      expect(BytesPerTileId.twoAndHalfK.id, '2.5k');
    });
  });

  group('bytesPerTile', () {
    test('has exactly the three profiles', () {
      expect(
        bytesPerTile.keys,
        unorderedEquals(<BytesPerTileId>[
          BytesPerTileId.oneK,
          BytesPerTileId.twoK,
          BytesPerTileId.twoAndHalfK,
        ]),
      );
    });

    test('each profile is pinned exactly', () {
      expectProfile(
        bytesPerTile[BytesPerTileId.oneK]!,
        version: 27,
        symbolSize: 1024,
        mtu: 1028,
        chunkSize: 1004,
        frameBudget: 1465,
      );
      expectProfile(
        bytesPerTile[BytesPerTileId.twoK]!,
        version: 34,
        symbolSize: 2048,
        mtu: 2052,
        chunkSize: 2028,
        frameBudget: 2188,
      );
      expectProfile(
        bytesPerTile[BytesPerTileId.twoAndHalfK]!,
        version: 40,
        symbolSize: 2560,
        mtu: 2564,
        chunkSize: 2540,
        frameBudget: 2953,
      );
    });

    test('every mtu is symbolSize + 4', () {
      for (final profile in bytesPerTile.values) {
        expect(
          profile.mtu,
          profile.symbolSize + 4,
          reason: 'mtu must equal symbolSize + 4',
        );
      }
    });

    test('every frame fits the QR symbol budget', () {
      for (final profile in bytesPerTile.values) {
        final frameLen = headerLen + profile.symbolSize + crcLen;
        expect(
          frameLen,
          lessThanOrEqualTo(profile.frameBudget),
          reason: 'frame $frameLen must fit frameBudget ${profile.frameBudget}',
        );
      }
    });

    test('is a compile-time const map', () {
      const map = bytesPerTile;
      expect(map.length, 3);
    });
  });

  group('layouts', () {
    test('cols and rows are pinned exactly', () {
      expect(layouts[LayoutId.single], (cols: 1, rows: 1));
      expect(layouts[LayoutId.column3], (cols: 1, rows: 3));
      expect(layouts[LayoutId.row3], (cols: 3, rows: 1));
      expect(layouts[LayoutId.grid4], (cols: 2, rows: 2));
      expect(layouts[LayoutId.grid9], (cols: 3, rows: 3));
    });
  });

  group('TransferSettings', () {
    test('is const-constructible and value-equal', () {
      const a = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 15,
        highRefresh: false,
      );
      const b = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 15,
        highRefresh: false,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('distinguishes differing fields', () {
      const base = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 15,
        highRefresh: false,
      );
      expect(
        base,
        isNot(
          TransferSettings(
            bytesPerTile: BytesPerTileId.twoK,
            layout: LayoutId.grid4,
            targetFps: 15,
            highRefresh: false,
          ),
        ),
      );
      expect(
        base,
        isNot(
          TransferSettings(
            bytesPerTile: BytesPerTileId.oneK,
            layout: LayoutId.single,
            targetFps: 15,
            highRefresh: false,
          ),
        ),
      );
      expect(
        base,
        isNot(
          TransferSettings(
            bytesPerTile: BytesPerTileId.oneK,
            layout: LayoutId.grid4,
            targetFps: 30,
            highRefresh: false,
          ),
        ),
      );
      expect(
        base,
        isNot(
          TransferSettings(
            bytesPerTile: BytesPerTileId.oneK,
            layout: LayoutId.grid4,
            targetFps: 15,
            highRefresh: true,
          ),
        ),
      );
    });

    test('fields are readable', () {
      const s = TransferSettings(
        bytesPerTile: BytesPerTileId.twoAndHalfK,
        layout: LayoutId.row3,
        targetFps: 30,
        highRefresh: true,
      );
      expect(s.bytesPerTile, BytesPerTileId.twoAndHalfK);
      expect(s.layout, LayoutId.row3);
      expect(s.targetFps, 30);
      expect(s.highRefresh, isTrue);
    });
  });
}

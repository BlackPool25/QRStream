/// Protocol constants — single source of truth for the QR transfer wire format.
/// Frame layout (30-byte header + payload + CRC-32C): port of
/// `src/protocol/constants.ts`.
library;

/// Magic bytes "QRDF".
const magicQrdf = <int>[0x51, 0x52, 0x44, 0x46];

/// Wire protocol version.
const protoVersion = 1;

/// Frame type: payload carries RaptorQ symbol bytes.
const typeData = 0x01;

/// Frame type: payload carries the metadata JSON document.
const typeMeta = 0x02;

/// Fixed header length in bytes.
const headerLen = 30;

/// CRC-32C trailer length in bytes.
const crcLen = 4;

/// Flags bitfield: bit0 set when the DATA payload was deflated.
const flagCompressed = 0x01;

/// The sender re-broadcasts the META frame every N display ticks.
const metadataRebroadcastEvery = 32;

/// sessionId length in bytes (8 bytes = 16 hex chars).
const sessionIdLen = 8;

/// Largest encodable totalLen: 24 bits = 16 MiB.
const maxTotalLen = 0xffffff;

/// Magic string inside the metadata JSON payload.
const metaMagic = 'QRDF-META';

/// Bytes per tile id (port of the `'1k' | '2k' | '2.5k'` string union).
enum BytesPerTileId {
  oneK('1k'),
  twoK('2k'),
  twoAndHalfK('2.5k');

  const BytesPerTileId(this.id);

  /// Wire-facing identifier, matching the TS string union exactly.
  final String id;
}

/// Tile layout id (port of the
/// `'single' | 'column2' | 'row2' | 'column3' | 'row3' | 'grid4' | 'grid9'`
/// string union). The `column2`/`row2` layouts drive the dual-lane schedule
/// (two position-stable tiles, one symbol per tick).
enum LayoutId { single, column2, row2, column3, row3, grid4, grid9 }

/// A QR display profile: QR version/ECC-agnostic sizing and frame budget.
class BytesPerTileProfile {
  const BytesPerTileProfile({
    required this.version,
    required this.symbolSize,
    required this.mtu,
    required this.chunkSize,
    required this.frameBudget,
  });

  /// QR code version for this tile size.
  final int version;

  /// RaptorQ symbol size in bytes.
  final int symbolSize;

  /// Maximum transfer unit (symbol + 4 RaptorQ overhead bytes).
  final int mtu;

  /// Payload chunk size carried per frame.
  final int chunkSize;

  /// Byte capacity of the QR version at ECC-L forced mask 2.
  final int frameBudget;
}

// Wire-fit sanity: mtu = symbolSize + 4; frame = 30 (header) + symbolSize + 4
// (CRC) and must fit frameBudget for all three profiles (1058/2082/2594 ≤ 1465/2188/2953).
const bytesPerTile = <BytesPerTileId, BytesPerTileProfile>{
  BytesPerTileId.oneK: BytesPerTileProfile(
    version: 27,
    symbolSize: 1024,
    mtu: 1028,
    chunkSize: 1004,
    frameBudget: 1465,
  ),
  BytesPerTileId.twoK: BytesPerTileProfile(
    version: 34,
    symbolSize: 2048,
    mtu: 2052,
    chunkSize: 2028,
    frameBudget: 2188,
  ),
  BytesPerTileId.twoAndHalfK: BytesPerTileProfile(
    version: 40,
    symbolSize: 2560,
    mtu: 2564,
    chunkSize: 2540,
    frameBudget: 2953,
  ),
};

/// Tiles per frame, as (cols, rows).
const layouts = <LayoutId, ({int cols, int rows})>{
  LayoutId.single: (cols: 1, rows: 1),
  LayoutId.column2: (cols: 1, rows: 2),
  LayoutId.row2: (cols: 2, rows: 1),
  LayoutId.column3: (cols: 1, rows: 3),
  LayoutId.row3: (cols: 3, rows: 1),
  LayoutId.grid4: (cols: 2, rows: 2),
  LayoutId.grid9: (cols: 3, rows: 3),
};

/// User-selectable transfer settings.
class TransferSettings {
  const TransferSettings({
    required this.bytesPerTile,
    required this.layout,
    required this.targetFps,
    required this.highRefresh,
  });

  /// Tile size (1k / 2k / 2.5k bytes per symbol).
  final BytesPerTileId bytesPerTile;

  /// Tiles per frame arrangement.
  final LayoutId layout;

  /// Broadcast cadence: 12 / 15 / 24 / 30.
  final int targetFps;

  /// Whether the high-refresh (90 Hz+) display path is in use.
  final bool highRefresh;

  @override
  bool operator ==(Object other) =>
      other is TransferSettings &&
      other.bytesPerTile == bytesPerTile &&
      other.layout == layout &&
      other.targetFps == targetFps &&
      other.highRefresh == highRefresh;

  @override
  int get hashCode => Object.hash(bytesPerTile, layout, targetFps, highRefresh);
}

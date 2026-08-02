/**
 * Protocol constants — single source of truth for the QRStream wire format.
 * Frame layout (30-byte header + payload + CRC32C): see wire.ts.
 */

/** Magic bytes "QRDF". */
export const MAGIC_QRDF = [0x51, 0x52, 0x44, 0x46] as const

/** Wire protocol version. */
export const PROTO_VERSION = 1

/** Frame type: payload carries RaptorQ symbol bytes. */
export const TYPE_DATA = 0x01 as const

/** Frame type: payload carries the metadata JSON document. */
export const TYPE_META = 0x02 as const

/** Fixed header length in bytes. */
export const HEADER_LEN = 30

/** CRC-32C trailer length in bytes. */
export const CRC_LEN = 4

/** Flags bitfield: bit0 set when the DATA payload was deflated. */
export const FLAG_COMPRESSED = 0x01

/** The sender re-broadcasts the META frame every N display ticks. */
export const METADATA_REBROADCAST_EVERY = 32

/** sessionId length in bytes (8 bytes = 16 hex chars). */
export const SESSION_ID_LEN = 8

/** Largest encodable totalLen: 24 bits = 16 MiB. */
export const MAX_TOTAL_LEN = 0xffffff

/** Magic string inside the metadata JSON payload. */
export const META_MAGIC = 'QRDF-META' as const

/** A QR display profile: grid layout, QR version/ECC and frame sizing. */
export interface Profile {
  readonly tiles: readonly [number, number]
  readonly version: number
  readonly ecc: 'L' | 'M' | 'Q' | 'H'
  readonly symbolSize: number
  readonly mtu: number
  readonly chunkSize: number
  readonly frameBudget: number
}

/** 2x2 QR grid profile (QR version 27, ~1KB symbols). */
export const PROFILE_GRID: Profile = {
  tiles: [2, 2],
  version: 27,
  ecc: 'L',
  symbolSize: 1024,
  mtu: 1028,
  chunkSize: 1004,
  frameBudget: 1465,
}

export type BytesPerTileId = '1k' | '2k' | '2.5k'

export interface BytesPerTileProfile {
  version: number
  symbolSize: number
  mtu: number
  chunkSize: number
  frameBudget: number
}

// Wire-fit sanity: each mtu = symbolSize + 4 (RaptorQ symbol = mtu − 4); each frame is
// 30 (header) + symbolSize + 4 (CRC) and must fit the QR version's Ecc.LOW byte capacity
// at forced mask 2 (the qrcodegen fast path we render with; slightly under the spec
// table: V27-L=1465, V34-L=2188, V40-L=2953). Rows verify: 1058/2082/2594 ≤ capacities.
export const BYTES_PER_TILE: Readonly<Record<BytesPerTileId, BytesPerTileProfile>> = {
  '1k': { version: 27, symbolSize: 1024, mtu: 1028, chunkSize: 1004, frameBudget: 1465 },
  '2k': { version: 34, symbolSize: 2048, mtu: 2052, chunkSize: 2028, frameBudget: 2188 },
  '2.5k': { version: 40, symbolSize: 2560, mtu: 2564, chunkSize: 2540, frameBudget: 2953 },
}

export type LayoutId = 'single' | 'column3' | 'row3' | 'grid4' | 'grid9'

export interface Layout {
  cols: number
  rows: number
}

export const LAYOUTS: Readonly<Record<LayoutId, Layout>> = {
  single: { cols: 1, rows: 1 },
  column3: { cols: 1, rows: 3 },
  row3: { cols: 3, rows: 1 },
  grid4: { cols: 2, rows: 2 },
  grid9: { cols: 3, rows: 3 },
}

export interface TransferSettings {
  bytesPerTile: BytesPerTileId
  layout: LayoutId
  targetFps: number
  highRefresh: boolean
}

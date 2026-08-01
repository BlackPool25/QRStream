/**
 * Protocol constants — single source of truth for the QR transfer wire format.
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

/** Single large QR profile (version 40, ~2KB symbols). */
export const PROFILE_V40: Profile = {
  tiles: [1, 1],
  version: 40,
  ecc: 'L',
  symbolSize: 2048,
  mtu: 2052,
  chunkSize: 2044,
  frameBudget: 2953,
}

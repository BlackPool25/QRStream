/**
 * Wire frame encode/decode — the single source of truth for the transfer
 * frame format.
 *
 * Frame = Header(30) + Payload(blockLen) + CRC32C(4), all little-endian:
 *   [0..3]   magic "QRDF" (0x51 0x52 0x44 0x46)
 *   [4]      protocol version (1)
 *   [5]      frame type: 0x01 DATA, 0x02 META
 *   [6..13]  sessionId (8 random bytes per send session)
 *   [14..17] esi u32 (RaptorQ encoding symbol id; 0 for META)
 *   [18..21] k u32 (total source symbols for this file)
 *   [22..25] blockLen u32 (payload length in THIS frame)
 *   [26..28] totalLen u24 (total file length post-compression, max 16 MiB)
 *   [29]     flags: bit0 = compressed, bits 1-7 reserved (must be 0)
 *
 * The CRC32C trailer covers header + payload; decode recomputes it and
 * rejects any mismatch. Decode exposes sessionId as a 16-char lowercase hex
 * string so receivers can dedup by (sessionId, esi).
 */

import {
  CRC_LEN,
  FLAG_COMPRESSED,
  HEADER_LEN,
  MAGIC_QRDF,
  MAX_TOTAL_LEN,
  PROTO_VERSION,
  SESSION_ID_LEN,
  TYPE_DATA,
  TYPE_META,
} from './constants'
import { crc32c } from './crc32c'

/** Failure codes for encode/decode validation. */
export type WireErrorCode =
  | 'BAD_MAGIC'
  | 'BAD_VERSION'
  | 'BAD_TYPE'
  | 'BAD_SESSION_ID'
  | 'BAD_ESI'
  | 'BAD_K'
  | 'BAD_TOTAL_LEN'
  | 'BAD_FLAGS'
  | 'TRUNCATED'
  | 'BAD_LENGTH'
  | 'BAD_CRC'

/** Typed protocol error; test and inspect via .code, never message text. */
export class ProtocolError extends Error {
  override readonly name = 'ProtocolError'
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

export type FrameType = typeof TYPE_DATA | typeof TYPE_META

/** A decoded frame. sessionId is 16 lowercase hex chars. */
export interface Frame {
  readonly type: FrameType
  readonly sessionId: string
  readonly esi: number
  readonly k: number
  readonly totalLen: number
  readonly flags: number
  readonly payload: Uint8Array
}

const SESSION_ID_RE = /^[0-9a-f]{16}$/i

function assertSessionId(sessionId: string): void {
  if (!SESSION_ID_RE.test(sessionId)) {
    throw new ProtocolError('BAD_SESSION_ID', `sessionId must be 16 hex chars, got "${sessionId}"`)
  }
}

function assertUint32(v: number, code: WireErrorCode, name: string): void {
  if (!Number.isInteger(v) || v < 0 || v > 0xffffffff) {
    throw new ProtocolError(code, `${name} must be a u32, got ${v}`)
  }
}

function assertFlags(flags: number): void {
  if (!Number.isInteger(flags) || (flags & ~FLAG_COMPRESSED) !== 0) {
    throw new ProtocolError('BAD_FLAGS', `flags must only use bit0 (compressed), got ${flags}`)
  }
}

/** Encode a frame (header + payload + CRC32C trailer). */
export function encodeFrame(frame: Frame): Uint8Array {
  if (frame.type !== TYPE_DATA && frame.type !== TYPE_META) {
    throw new ProtocolError('BAD_TYPE', `frame type must be 0x01 or 0x02, got ${frame.type}`)
  }
  assertSessionId(frame.sessionId)
  assertUint32(frame.esi, 'BAD_ESI', 'esi')
  assertUint32(frame.k, 'BAD_K', 'k')
  assertFlags(frame.flags)
  if (!Number.isInteger(frame.totalLen) || frame.totalLen < 0 || frame.totalLen > MAX_TOTAL_LEN) {
    throw new ProtocolError('BAD_TOTAL_LEN', `totalLen must fit 24 bits, got ${frame.totalLen}`)
  }

  const blockLen = frame.payload.length
  const out = new Uint8Array(HEADER_LEN + blockLen + CRC_LEN)
  const view = new DataView(out.buffer)

  for (let i = 0; i < MAGIC_QRDF.length; i++) {
    out[i] = MAGIC_QRDF[i]!
  }
  out[4] = PROTO_VERSION
  out[5] = frame.type
  for (let i = 0; i < SESSION_ID_LEN; i++) {
    out[6 + i] = parseInt(frame.sessionId.slice(i * 2, i * 2 + 2), 16)
  }
  view.setUint32(14, frame.esi, true)
  view.setUint32(18, frame.k, true)
  view.setUint32(22, blockLen, true)
  out[26] = frame.totalLen & 0xff
  out[27] = (frame.totalLen >>> 8) & 0xff
  out[28] = (frame.totalLen >>> 16) & 0xff
  out[29] = frame.flags
  out.set(frame.payload, HEADER_LEN)

  const crc = crc32c(out.subarray(0, HEADER_LEN + blockLen))
  view.setUint32(HEADER_LEN + blockLen, crc, true)
  return out
}

function hexSessionId(bytes: Uint8Array, offset: number): string {
  let hex = ''
  for (let i = 0; i < SESSION_ID_LEN; i++) {
    hex += bytes[offset + i]!.toString(16).padStart(2, '0')
  }
  return hex
}

/** Decode and strictly validate a full frame; throws ProtocolError on any violation. */
export function decodeFrame(bytes: Uint8Array): Frame {
  if (bytes.length < HEADER_LEN + CRC_LEN) {
    throw new ProtocolError('TRUNCATED', `frame shorter than header + CRC (${bytes.length} bytes)`)
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

  for (let i = 0; i < MAGIC_QRDF.length; i++) {
    if (bytes[i] !== MAGIC_QRDF[i]) {
      throw new ProtocolError('BAD_MAGIC', 'frame magic mismatch')
    }
  }
  if (bytes[4] !== PROTO_VERSION) {
    throw new ProtocolError('BAD_VERSION', `unsupported protocol version ${bytes[4]}`)
  }
  const type = bytes[5]!
  if (type !== TYPE_DATA && type !== TYPE_META) {
    throw new ProtocolError('BAD_TYPE', `unknown frame type 0x${type.toString(16)}`)
  }
  const flags = bytes[29]!
  if ((flags & ~FLAG_COMPRESSED) !== 0) {
    throw new ProtocolError('BAD_FLAGS', `reserved flag bits set: 0x${flags.toString(16)}`)
  }

  const blockLen = view.getUint32(22, true)
  const expected = HEADER_LEN + blockLen + CRC_LEN
  if (bytes.length < expected) {
    throw new ProtocolError(
      'TRUNCATED',
      `frame declares blockLen ${blockLen} but only ${bytes.length} bytes present`,
    )
  }
  if (bytes.length !== expected) {
    throw new ProtocolError('BAD_LENGTH', `frame is ${bytes.length} bytes, expected ${expected}`)
  }

  const computed = crc32c(bytes.subarray(0, HEADER_LEN + blockLen))
  if (view.getUint32(HEADER_LEN + blockLen, true) !== computed) {
    throw new ProtocolError('BAD_CRC', 'CRC32C mismatch')
  }

  return {
    type,
    sessionId: hexSessionId(bytes, 6),
    esi: view.getUint32(14, true),
    k: view.getUint32(18, true),
    totalLen: bytes[26]! | (bytes[27]! << 8) | (bytes[28]! << 16),
    flags,
    payload: bytes.slice(HEADER_LEN, HEADER_LEN + blockLen),
  }
}

/** Generate a fresh 8-byte session id as 16 lowercase hex chars. */
export function generateSessionId(): string {
  const bytes = new Uint8Array(SESSION_ID_LEN)
  crypto.getRandomValues(bytes)
  return hexSessionId(bytes, 0)
}

/**
 * Metadata frame build/parse.
 *
 * A META frame's payload is a UTF-8 JSON document with exact keys:
 *   magic, protoVer, sessionId, filename, mime, totalSize, compressedSize,
 *   compressed, k, symbolSize, mtu, fileSHA256, flags
 * The sender re-broadcasts the META frame every METADATA_REBROADCAST_EVERY
 * display ticks; receivers parse it via parseMetadataFrame.
 */

import { META_MAGIC, PROTO_VERSION, TYPE_META, FLAG_COMPRESSED, MAX_TOTAL_LEN } from './constants'
import { decodeFrame, encodeFrame, ProtocolError } from './wire'

/** Decoded metadata document. sessionId and fileSHA256 are lowercase hex. */
export interface Metadata {
  readonly magic: typeof META_MAGIC
  readonly protoVer: number
  readonly sessionId: string
  readonly filename: string
  readonly mime: string
  readonly totalSize: number
  readonly compressedSize: number
  readonly compressed: boolean
  readonly k: number
  readonly symbolSize: number
  readonly mtu: number
  readonly fileSHA256: string
  readonly flags: number
}

const SESSION_ID_RE = /^[0-9a-f]{16}$/i
const SHA256_RE = /^[0-9a-f]{64}$/i

function fieldError(key: string, expected: string): ProtocolError {
  return new ProtocolError('BAD_METADATA_FIELD', `metadata.${key} must be ${expected}`)
}

function reqString(rec: Record<string, unknown>, key: string): string {
  const v = rec[key]
  if (typeof v !== 'string') throw fieldError(key, 'a string')
  return v
}

function reqNumber(rec: Record<string, unknown>, key: string): number {
  const v = rec[key]
  if (typeof v !== 'number' || !Number.isFinite(v)) throw fieldError(key, 'a finite number')
  return v
}

function reqBoolean(rec: Record<string, unknown>, key: string): boolean {
  const v = rec[key]
  if (typeof v !== 'boolean') throw fieldError(key, 'a boolean')
  return v
}

function assertUint(v: number, max: number, key: string): void {
  if (!Number.isInteger(v) || v < 0 || v > max) throw fieldError(key, `an integer in [0, ${max}]`)
}

/** Full semantic validation shared by build and parse paths. */
function validateMetadata(meta: Metadata): void {
  if (meta.magic !== META_MAGIC)
    throw new ProtocolError('BAD_METADATA_MAGIC', 'metadata magic mismatch')
  if (meta.protoVer !== PROTO_VERSION) {
    throw new ProtocolError(
      'BAD_METADATA_VERSION',
      `unsupported metadata protoVer ${meta.protoVer}`,
    )
  }
  if (!SESSION_ID_RE.test(meta.sessionId)) throw fieldError('sessionId', '16 hex chars')
  if (!SHA256_RE.test(meta.fileSHA256)) throw fieldError('fileSHA256', '64 hex chars')
  assertUint(meta.totalSize, 0xffffffff, 'totalSize')
  assertUint(meta.compressedSize, MAX_TOTAL_LEN, 'compressedSize')
  assertUint(meta.k, 0xffffffff, 'k')
  assertUint(meta.symbolSize, 0xffffffff, 'symbolSize')
  assertUint(meta.mtu, 0xffffffff, 'mtu')
  assertUint(meta.flags, FLAG_COMPRESSED, 'flags')
  if (meta.compressed !== meta.compressedSize > 0) {
    throw fieldError('compressed', 'consistent with compressedSize (0 when uncompressed)')
  }
}

/** Serialize a metadata document to its JSON payload bytes. */
export function buildMetadataPayload(meta: Metadata): Uint8Array {
  validateMetadata(meta)
  return new TextEncoder().encode(JSON.stringify(meta))
}

/** Parse and strictly validate metadata JSON payload bytes. */
export function parseMetadataPayload(bytes: Uint8Array): Metadata {
  let rec: Record<string, unknown>
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes))
    if (typeof parsed !== 'object' || parsed === null) {
      throw new Error('not an object')
    }
    rec = parsed as Record<string, unknown>
  } catch {
    throw new ProtocolError('BAD_METADATA_JSON', 'metadata payload is not a JSON object')
  }

  // Narrow magic to its literal type via a guard — no cast needed.
  const magic = reqString(rec, 'magic')
  if (magic !== META_MAGIC) throw new ProtocolError('BAD_METADATA_MAGIC', 'metadata magic mismatch')

  const meta: Metadata = {
    magic,
    protoVer: reqNumber(rec, 'protoVer'),
    sessionId: reqString(rec, 'sessionId'),
    filename: reqString(rec, 'filename'),
    mime: reqString(rec, 'mime'),
    totalSize: reqNumber(rec, 'totalSize'),
    compressedSize: reqNumber(rec, 'compressedSize'),
    compressed: reqBoolean(rec, 'compressed'),
    k: reqNumber(rec, 'k'),
    symbolSize: reqNumber(rec, 'symbolSize'),
    mtu: reqNumber(rec, 'mtu'),
    fileSHA256: reqString(rec, 'fileSHA256'),
    flags: reqNumber(rec, 'flags'),
  }
  validateMetadata(meta)
  return meta
}

/** Build a full META wire frame (esi=0, header sessionId = payload sessionId). */
export function buildMetadataFrame(meta: Metadata): Uint8Array {
  const payload = buildMetadataPayload(meta)
  return encodeFrame({
    type: TYPE_META,
    sessionId: meta.sessionId,
    esi: 0,
    k: meta.k,
    totalLen: meta.compressedSize,
    flags: 0,
    payload,
  })
}

/** Decode a META frame and parse its metadata payload. */
export function parseMetadataFrame(bytes: Uint8Array): Metadata {
  const frame = decodeFrame(bytes)
  if (frame.type !== TYPE_META) {
    throw new ProtocolError(
      'NOT_META',
      `expected a META frame, got type 0x${frame.type.toString(16)}`,
    )
  }
  const meta = parseMetadataPayload(frame.payload)
  if (meta.sessionId !== frame.sessionId) {
    throw new ProtocolError(
      'SESSION_ID_MISMATCH',
      'metadata sessionId differs from frame sessionId',
    )
  }
  return meta
}

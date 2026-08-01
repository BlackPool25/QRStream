/**
 * Sender pipeline: file bytes -> best-effort deflate -> RaptorQ fountain
 * encode -> DATA frames + a META frame, ready for the display loop.
 *
 * Pure module: no DOM, no File API — input is a Uint8Array plus strings, so
 * the whole pipeline is unit-testable under Node.
 *
 * Frame ownership: `dataFrames` holds every source-symbol DATA frame;
 * `metaFrames` holds exactly ONE META frame, which the display loop re-emits
 * every METADATA_REBROADCAST_EVERY ticks (see constants.ts). The `encoder`
 * is kept alive on the PreparedTransfer so the caller can generate repair
 * frames on demand (repairFrames); the caller disposes it when the broadcast
 * stops. No encryption: this is a pure broadcast with no pairing.
 *
 * Empty input is rejected with EMPTY_FILE: RaptorQ cannot encode a
 * zero-length payload, so an empty transfer has no valid wire representation.
 */

import { compress } from '../codec/compression/deflate'
import { createRaptorqFountain } from '../codec/fountain/raptorq'
import type { EncodedSymbol, FountainEncoder } from '../codec/fountain/interface'
import {
  BYTES_PER_TILE,
  FLAG_COMPRESSED,
  MAX_TOTAL_LEN,
  META_MAGIC,
  PROTO_VERSION,
  TYPE_DATA,
  type TransferSettings,
} from '../protocol/constants'
import { buildMetadataFrame } from '../protocol/metadata'
import { sha256Hex } from '../protocol/sha256'
import { encodeFrame, generateSessionId, type Frame } from '../protocol/wire'
import { DEFAULT_TRANSFER_SETTINGS, validateSettings } from './settings'

export interface TransferInfo {
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
  readonly settings: TransferSettings
  readonly totalFrames: number
  readonly dataFrameCount: number
  readonly metaFrameCount: number
}

export interface PreparedTransfer {
  readonly info: TransferInfo
  /** Every source-symbol DATA wire frame (payload = one RaptorQ symbol). */
  readonly dataFrames: readonly Uint8Array[]
  /** Exactly one META wire frame; the display loop re-emits it at cadence. */
  readonly metaFrames: readonly Uint8Array[]
  /** Kept alive for repair generation; caller disposes when broadcast stops. */
  readonly encoder: FountainEncoder
}

export type PipelineErrorCode =
  'EMPTY_FILE' | 'TOO_LARGE' | 'K_SANITY_FAILED' | 'FRAME_TOO_LARGE' | 'BAD_REPAIR_COUNT'

/** Typed pipeline error; inspect via .code, never message text. */
export class PipelineError extends Error {
  override readonly name = 'PipelineError'
  readonly code: PipelineErrorCode

  constructor(code: PipelineErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

export async function prepareTransfer(input: {
  file: Uint8Array
  filename: string
  mime: string
  settings?: TransferSettings
}): Promise<PreparedTransfer> {
  if (input.file.length === 0) {
    throw new PipelineError('EMPTY_FILE', 'cannot transfer an empty file')
  }

  // Normalize to a fresh ArrayBuffer-backed copy: WebCrypto's sha256Hex and
  // the codec both require Uint8Array<ArrayBuffer>.
  const file = new Uint8Array(input.file)

  const settings = input.settings ?? DEFAULT_TRANSFER_SETTINGS
  validateSettings(settings)
  const profile = BYTES_PER_TILE[settings.bytesPerTile]

  const totalSize = file.length
  const fileSHA256 = await sha256Hex(file)

  // Best-effort deflate; the codec skips when it would not shrink the payload.
  const { data: payloadBytes, compressed } = compress(file)
  const compressedSize = payloadBytes.length
  if (compressedSize > MAX_TOTAL_LEN) {
    throw new PipelineError(
      'TOO_LARGE',
      `payload ${compressedSize} B exceeds the ${MAX_TOTAL_LEN} B wire totalLen limit`,
    )
  }

  // RaptorQ takes the ENTIRE payload as one input: the codec computes
  // K = ceil(len / (mtu - 4)) internally, so there is no manual chunking.
  const encoder = await createRaptorqFountain().createEncoder(payloadBytes, profile.mtu)

  const k = encoder.sourceSymbolCount
  if (k * encoder.symbolSize < compressedSize) {
    throw new PipelineError(
      'K_SANITY_FAILED',
      `encoder reported k=${k} symbols of ${encoder.symbolSize} B < payload ${compressedSize} B`,
    )
  }
  if (encoder.symbolSize > profile.frameBudget) {
    throw new PipelineError(
      'FRAME_TOO_LARGE',
      `symbol size ${encoder.symbolSize} B exceeds the profile frameBudget of ${profile.frameBudget} B`,
    )
  }

  const sessionId = generateSessionId()
  const flags = compressed ? FLAG_COMPRESSED : 0

  const dataFrames = encoder
    .encodeSourceSymbols()
    .map((symbol) => buildDataFrame(sessionId, k, compressedSize, flags, symbol))

  const metaFrame = buildMetadataFrame({
    magic: META_MAGIC,
    protoVer: PROTO_VERSION,
    sessionId,
    filename: input.filename,
    mime: input.mime,
    totalSize,
    // The protocol pins metadata.compressedSize to 0 when uncompressed
    // (protocol/metadata.ts), while the DATA frames carry the true wire
    // length in totalLen and TransferInfo.compressedSize.
    compressedSize: compressed ? compressedSize : 0,
    compressed,
    k,
    symbolSize: encoder.symbolSize,
    mtu: profile.mtu,
    fileSHA256,
    flags,
  })

  const info: TransferInfo = {
    sessionId,
    filename: input.filename,
    mime: input.mime,
    totalSize,
    compressedSize,
    compressed,
    k,
    symbolSize: encoder.symbolSize,
    mtu: profile.mtu,
    fileSHA256,
    settings,
    totalFrames: dataFrames.length + 1,
    dataFrameCount: dataFrames.length,
    metaFrameCount: 1,
  }

  return { info, dataFrames, metaFrames: [metaFrame], encoder }
}

function buildDataFrame(
  sessionId: string,
  k: number,
  totalLen: number,
  flags: number,
  symbol: EncodedSymbol,
): Uint8Array {
  const frame: Frame = {
    type: TYPE_DATA,
    sessionId,
    esi: symbol.esi,
    k,
    totalLen,
    flags,
    payload: symbol.bytes,
  }
  return encodeFrame(frame)
}

/** Build `repairCount` additional DATA frames from the encoder's repair symbols. */
export function repairFrames(prepared: PreparedTransfer, repairCount: number): Uint8Array[] {
  if (!Number.isInteger(repairCount) || repairCount < 0) {
    throw new PipelineError(
      'BAD_REPAIR_COUNT',
      `repairCount must be a non-negative integer, got ${repairCount}`,
    )
  }
  const { sessionId, k, compressedSize, compressed } = prepared.info
  const flags = compressed ? FLAG_COMPRESSED : 0
  // encodeRepair returns the K source symbols followed by `count` repair
  // symbols (see codec/fountain/interface.ts), so slice off the source set.
  return prepared.encoder
    .encodeRepair(repairCount)
    .slice(k)
    .map((symbol) => buildDataFrame(sessionId, k, compressedSize, flags, symbol))
}

/** Bytes carried on the wire for this transfer (post-compression size). */
export function transferBytes(info: TransferInfo): number {
  return info.compressedSize
}

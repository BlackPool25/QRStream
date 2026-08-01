/**
 * Receiver-side reassembly: RaptorQ fountain decode -> (optional) inflate ->
 * SHA-256 integrity gate -> the original file bytes, ready for save.
 *
 * The decoder is one-shot per file, so a fresh Reassembler handles one
 * transfer; the camera keeps feeding symbols via feedMore() until isComplete.
 * Pure module (no DOM, no File API) and fully Node-testable.
 *
 * Integrity layering: CRC32C guards each frame, RaptorQ guards erasure, and
 * the SHA-256 comparison here is the whole-file gate — finish() only reports
 * verified=true when the decompressed bytes exactly match metadata.fileSHA256.
 */

import { decompress } from '../codec/compression/deflate'
import { createRaptorqFountain } from '../codec/fountain/raptorq'
import type { FountainDecoder, FountainFactory } from '../codec/fountain/interface'
import type { Metadata } from '../protocol/metadata'
import { sha256Hex } from '../protocol/sha256'

export type ReassemblyErrorCode = 'not-complete' | 'hash-mismatch' | 'decode-failed'

/** Typed reassembly error; inspect via .code, never message text. */
export class ReassemblyError extends Error {
  override readonly name = 'ReassemblyError'
  readonly code: ReassemblyErrorCode

  constructor(code: ReassemblyErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

export interface ReassemblyResult {
  /** The decompressed original file (byte-identical to the sender's file). */
  readonly bytes: Uint8Array
  /** SHA-256 of `bytes`, matching metadata.fileSHA256 when verified. */
  readonly sha256: string
  /** Always true: a mismatching hash throws instead of returning. */
  readonly verified: boolean
  readonly mime: string
  readonly filename: string
}

export interface ReassemblerOptions {
  /** From the transfer profile (grid=1028, v40=2052). */
  readonly mtu: number
}

let fountainFactory: FountainFactory | undefined

function getFountainFactory(): FountainFactory {
  if (fountainFactory === undefined) {
    fountainFactory = createRaptorqFountain()
  }
  return fountainFactory
}

export class Reassembler {
  private readonly mtu: number
  private metadata: Metadata | undefined
  private decoder: FountainDecoder | undefined
  private output: Uint8Array | undefined
  private started = false
  private failed = false

  constructor(opts: ReassemblerOptions) {
    this.mtu = opts.mtu
  }

  /**
   * Creates the decoder and feeds the first batch of symbols. The wasm decoder
   * is one-shot, so start() rejects if the instance is already in use.
   */
  async start(metadata: Metadata, symbols: Uint8Array[], esiSet: Set<number>): Promise<void> {
    if (this.started) {
      throw new ReassemblyError('decode-failed', 'Reassembler.start called twice — call reset()')
    }
    this.started = true
    this.metadata = metadata

    const totalLength = metadata.compressed ? metadata.compressedSize : metadata.totalSize
    if (totalLength === 0) {
      // The codec cannot represent a zero-length transfer (its wasm panics on
      // transfer_length 0) and the sender rejects empty files, so a 0-byte
      // file is fully received the moment its metadata arrives.
      this.output = new Uint8Array(0)
      return
    }

    try {
      this.decoder = await getFountainFactory().createDecoder(totalLength, this.mtu)
    } catch {
      throw new ReassemblyError(
        'decode-failed',
        `could not create a decoder for a ${totalLength}-byte transfer`,
      )
    }
    this.feedMore(symbols, esiSet)
  }

  /**
   * Feeds newly scanned symbols. The caller dedups by esi (FrameBuffer); the
   * decoder ignores duplicate packets anyway, so everything given is fed.
   */
  feedMore(symbols: Uint8Array[], esiSet: Set<number>): void {
    void esiSet
    if (this.decoder === undefined || this.output !== undefined) {
      return
    }
    for (const symbol of symbols) {
      let result: Uint8Array | undefined
      try {
        result = this.decoder.decode(symbol)
      } catch {
        this.disposeDecoder()
        this.failed = true
        return
      }
      if (result !== undefined) {
        this.output = result
        this.disposeDecoder()
        return
      }
    }
  }

  /** True once the fountain decoder has produced the full payload. */
  get isComplete(): boolean {
    return this.output !== undefined
  }

  /** The fountain-decoded bytes (the compressed payload when compressed). */
  get decoded(): Uint8Array | undefined {
    return this.output
  }

  /**
   * Decompresses, verifies the SHA-256 against the metadata, and returns the
   * original file. Throws ReassemblyError('hash-mismatch') when the bytes do
   * not match — the data-loss detector a "verified" badge depends on.
   */
  async finish(): Promise<ReassemblyResult> {
    const metadata = this.metadata
    const output = this.output
    if (this.failed) {
      throw new ReassemblyError('decode-failed', 'fountain decode failed')
    }
    if (metadata === undefined || output === undefined) {
      throw new ReassemblyError('not-complete', 'not enough symbols to reassemble the file')
    }

    let payload: Uint8Array
    try {
      payload = metadata.compressed ? decompress({ data: output, compressed: true }) : output
    } catch {
      throw new ReassemblyError('decode-failed', 'decompressing the decoded payload failed')
    }
    // sha256Hex (and Blob/write) require an ArrayBuffer-backed view.
    const bytes = new Uint8Array(payload)

    const sha256 = await sha256Hex(bytes)
    if (sha256 !== metadata.fileSHA256) {
      throw new ReassemblyError(
        'hash-mismatch',
        'reassembled bytes do not match the file SHA-256 in the metadata',
      )
    }
    return { bytes, sha256, verified: true, mime: metadata.mime, filename: metadata.filename }
  }

  /** Clears all state so the instance can handle a new transfer. */
  reset(): void {
    this.disposeDecoder()
    this.metadata = undefined
    this.output = undefined
    this.started = false
    this.failed = false
  }

  private disposeDecoder(): void {
    if (this.decoder !== undefined) {
      this.decoder.dispose()
      this.decoder = undefined
    }
  }
}

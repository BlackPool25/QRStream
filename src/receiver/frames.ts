/**
 * Receiver-side frame buffering: session latching, esi dedup, and bounded
 * repair retention for the wire-frame stream.
 *
 * The sender broadcasts a continuous stream of DATA frames (RaptorQ source and
 * repair symbols) plus a META frame re-broadcast every METADATA_REBROADCAST_EVERY
 * ticks. This buffer is the receiver's "keep scanning" core: it latches onto the
 * newest sessionId (a new sender sessionId means a fresh transfer — the buffer
 * resets and starts over), dedups DATA payloads by esi, keeps the latest
 * metadata, and bounds memory by evicting the oldest repair symbols once the
 * distinct-symbol count exceeds k plus the repair budget.
 *
 * Pure (no DOM, no async) and deterministic, so it is fully Node-testable.
 * Reassembly (RaptorQ decode) is a later task and consumes this buffer via
 * symbols() and k.
 */

import { TYPE_DATA } from '../protocol/constants'
import { parseMetadataPayload, type Metadata } from '../protocol/metadata'
import { decodeFrame, ProtocolError, type Frame } from '../protocol/wire'

/** A decoded wire frame as received by the buffer. */
export type ReceivedFrame = Frame

/** Outcome of feeding one raw byte slice into the buffer. */
export type FeedStatus = 'ok' | 'dropped' | 'error'

export interface FeedResult {
  readonly status: FeedStatus
  /** Present when the bytes decoded to a frame (status ok or dropped). */
  readonly frame?: ReceivedFrame
  /** True when this feed latched onto a different sessionId. */
  readonly isNewSession?: boolean
  /** The parsed metadata when this feed was an accepted META frame. */
  readonly meta?: Metadata
}

export interface FrameBufferOptions {
  /**
   * Max number of distinct repair symbols (esi >= k) retained beyond the k
   * source symbols. Default: floor(k * 0.3) + 1000, i.e. a total cap of about
   * 1.3k + 1000 symbols. Fountain decode needs only k source symbols plus a
   * little repair slack; extra repair wastes memory and is evicted oldest
   * first (lowest esi, since repair esi grow over the broadcast).
   */
  readonly repairBudget?: number
}

export class FrameBuffer {
  private currentSessionId: string | undefined
  private meta: Metadata | undefined
  private latestK: number | undefined
  private readonly payloadByEsi = new Map<number, Uint8Array>()
  private readonly seenEsi = new Set<number>()
  private framesSeen = 0
  private dropped = 0
  private readonly repairBudget: number | undefined

  constructor(options: FrameBufferOptions = {}) {
    this.repairBudget = options.repairBudget
  }

  /**
   * Feeds one raw wire-frame byte slice. Never throws for protocol-level
   * corruption: undecodable bytes yield `{ status: 'error' }` and increment
   * droppedCount; a META payload that fails to parse yields
   * `{ status: 'dropped' }` (also a drop). A frame whose sessionId differs
   * from the current one resets the buffer and latches the new session
   * (broadcast restart semantics).
   */
  feed(rawBytes: Uint8Array): FeedResult {
    let frame: Frame
    try {
      frame = decodeFrame(rawBytes)
    } catch (error) {
      if (error instanceof ProtocolError) {
        this.dropped++
        return { status: 'error' }
      }
      throw error
    }
    this.framesSeen++

    let isNewSession = false
    if (frame.sessionId !== this.currentSessionId) {
      this.resetSessionState()
      this.currentSessionId = frame.sessionId
      isNewSession = true
    }

    if (frame.type === TYPE_DATA) {
      this.latestK = frame.k
      this.storeSymbol(frame)
      return { status: 'ok', frame, isNewSession }
    }

    try {
      const meta = parseMetadataPayload(frame.payload)
      if (meta.sessionId !== frame.sessionId) {
        throw new ProtocolError('SESSION_ID_MISMATCH', 'metadata sessionId differs from frame')
      }
      this.meta = meta
      this.latestK = meta.k
      return { status: 'ok', frame, isNewSession, meta }
    } catch (error) {
      if (error instanceof ProtocolError) {
        this.dropped++
        return { status: 'dropped', frame, isNewSession }
      }
      throw error
    }
  }

  /** Number of distinct (sessionId, esi) DATA payloads currently held. */
  get uniqueSymbolCount(): number {
    return this.payloadByEsi.size
  }

  /** Count of successfully decoded frames, including duplicates. */
  get totalFramesSeen(): number {
    return this.framesSeen
  }

  /** Count of frames dropped as corrupt or invalid (see {@link feed}). */
  get droppedCount(): number {
    return this.dropped
  }

  /** Metadata of the current session (undefined until a META frame arrives). */
  get metadata(): Metadata | undefined {
    return this.meta
  }

  /** SessionId of the current session. */
  get sessionId(): string | undefined {
    return this.currentSessionId
  }

  /** k of the current session, from META or the latest DATA header. */
  get k(): number | undefined {
    return this.latestK
  }

  /** Distinct DATA payloads sorted by esi (source symbols first, then repair). */
  symbols(): Uint8Array[] {
    return [...this.payloadByEsi.entries()].sort(([a], [b]) => a - b).map(([, payload]) => payload)
  }

  /** Esis of the distinct DATA payloads currently held. */
  symbolEsiSet(): Set<number> {
    return new Set(this.payloadByEsi.keys())
  }

  /**
   * Clears all session state (symbols, metadata, k, sessionId). The cumulative
   * counters totalFramesSeen/droppedCount are scan-health stats and survive.
   */
  reset(): void {
    this.resetSessionState()
  }

  private storeSymbol(frame: Frame): void {
    const { esi, payload, k } = frame
    if (!this.seenEsi.has(esi)) {
      this.seenEsi.add(esi)
      this.payloadByEsi.set(esi, payload)
    }
    const budget = this.repairBudget ?? Math.floor(k * 0.3) + 1000
    const maxSymbols = k + budget
    if (this.payloadByEsi.size > maxSymbols) {
      this.evictOldestRepair(maxSymbols, k)
    }
  }

  private evictOldestRepair(maxSymbols: number, k: number): void {
    const repairEsi = [...this.payloadByEsi.keys()].filter((esi) => esi >= k).sort((a, b) => a - b)
    for (const esi of repairEsi) {
      if (this.payloadByEsi.size <= maxSymbols) {
        break
      }
      this.payloadByEsi.delete(esi)
      this.seenEsi.delete(esi)
    }
  }

  private resetSessionState(): void {
    this.currentSessionId = undefined
    this.meta = undefined
    this.latestK = undefined
    this.seenEsi.clear()
    this.payloadByEsi.clear()
  }
}

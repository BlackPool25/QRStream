/**
 * Pure receiver stats/derived-state core — fully Node-testable, no DOM.
 *
 * Splitting this out of orchestrate.ts keeps every file under the 250-LOC
 * ceiling: the numbers the StatusOverlay shows (progress, ETA, decode rate,
 * downsample target, feed/reassembler bookkeeping) live here, while the
 * browser shell (ReceiverOrchestrator) lives in orchestrate.ts and re-exports
 * these names unchanged.
 */

import type { Metadata } from '../protocol/metadata'
import { FrameBuffer, type FeedResult } from './frames'

const MAX_PIXELS = 2_000_000
const MAX_DOWNSAMPLE_WIDTH = 1280

export type ReceiverStatus = 'idle' | 'scanning' | 'transferring' | 'complete' | 'error'

export interface ReceiverStats {
  readonly status: ReceiverStatus
  readonly unique: number
  readonly k: number | undefined
  readonly totalFramesSeen: number
  readonly droppedCount: number
  /** Decoded video frames per second (EMA). */
  readonly decodeRate: number
  readonly bytesPerSecond: number
  readonly etaSeconds: number | undefined
  /** 0..1: unique/k when k is known, else 0. */
  readonly progress: number
  readonly metaSeen: boolean
  readonly fileName: string | undefined
  readonly verified: boolean | undefined
}

export interface StatsSample {
  readonly unique: number
  readonly k: number | undefined
  readonly totalFramesSeen: number
  readonly droppedCount: number
  readonly elapsedMs: number
  readonly symbolSize: number | undefined
  /** Decoded frames counted inside this stats window. */
  readonly decodedInWindow: number
  readonly windowMs: number
}

/** Draw target for a camera capture: at most 2MP and never wider than 1280px. */
export function downsampleTarget(
  captureWidth: number,
  captureHeight: number,
): { width: number; height: number } {
  if (captureWidth <= 0 || captureHeight <= 0) {
    return { width: 1, height: 1 }
  }
  const scale = Math.min(
    1,
    Math.sqrt(MAX_PIXELS / (captureWidth * captureHeight)),
    MAX_DOWNSAMPLE_WIDTH / captureWidth,
  )
  let width = Math.max(1, Math.round(captureWidth * scale))
  let height = Math.max(1, Math.round(captureHeight * scale))
  while (width * height > MAX_PIXELS) {
    if (width > height) {
      width -= 1
    } else {
      height -= 1
    }
  }
  return { width, height }
}

/** Seconds to receive the remaining symbols; undefined while unknowable. */
export function estimateEta(
  unique: number,
  k: number | undefined,
  bytesPerSecond: number,
  symbolSize: number | undefined,
): number | undefined {
  if (
    k === undefined ||
    k <= 0 ||
    bytesPerSecond <= 0 ||
    symbolSize === undefined ||
    symbolSize <= 0
  ) {
    return undefined
  }
  if (unique >= k) {
    // The frame buffer counts repair symbols (esi >= k) too, so unique meeting
    // or exceeding k does not mean the transfer is done — the decoder is still
    // working. ETA of 0 would read as "complete", so it must be unknowable.
    return undefined
  }
  return ((k - unique) * symbolSize) / bytesPerSecond
}

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value))
}

function progressOf(unique: number, k: number | undefined): number {
  if (k === undefined || k <= 0) {
    return 0
  }
  return clamp01(unique / k)
}

function instantaneousRate(decodedInWindow: number, windowMs: number): number {
  return windowMs <= 0 ? 0 : (decodedInWindow / windowMs) * 1000
}

/** EMA blend with a 1s time constant, clamped to the window length. */
function emaBlend(prev: number, instant: number, windowMs: number): number {
  if (windowMs <= 0) {
    return prev
  }
  const alpha = Math.min(1, windowMs / 1000)
  return prev * (1 - alpha) + instant * alpha
}

/** A zeroed snapshot suitable as the first `prev` for updateStats. */
export const EMPTY_STATS: ReceiverStats = {
  status: 'idle',
  unique: 0,
  k: undefined,
  totalFramesSeen: 0,
  droppedCount: 0,
  decodeRate: 0,
  bytesPerSecond: 0,
  etaSeconds: undefined,
  progress: 0,
  metaSeen: false,
  fileName: undefined,
  verified: undefined,
}

function statsOf(
  prev: ReceiverStats,
  sample: StatsSample,
  decodeRate: number,
  bytesPerSecond: number,
): ReceiverStats {
  return {
    status: prev.status,
    unique: sample.unique,
    k: sample.k,
    totalFramesSeen: sample.totalFramesSeen,
    droppedCount: sample.droppedCount,
    decodeRate,
    bytesPerSecond,
    etaSeconds: estimateEta(sample.unique, sample.k, bytesPerSecond, sample.symbolSize),
    progress: progressOf(sample.unique, sample.k),
    metaSeen: sample.symbolSize !== undefined,
    fileName: prev.fileName,
    verified: prev.verified,
  }
}

/** Stateless projection: decodeRate is this window's instantaneous rate. */
export function computeStats(sample: StatsSample): ReceiverStats {
  return statsOf(
    EMPTY_STATS,
    sample,
    instantaneousRate(sample.decodedInWindow, sample.windowMs),
    sample.symbolSize !== undefined && sample.symbolSize > 0 && sample.elapsedMs > 0
      ? (sample.unique * sample.symbolSize) / (sample.elapsedMs / 1000)
      : 0,
  )
}

/**
 * Windowed receive rate: how many NEW symbols arrived in this window, times
 * the symbol size, per second — EMA-blended with the previous rate. Unlike a
 * lifetime average (unique × size / total elapsed), this reflects the current
 * decode throughput and drops when the sender's cadence slows or the receiver
 * starts missing frames, so the ETA it feeds stays honest.
 */
function windowedBytesPerSecond(prev: ReceiverStats, sample: StatsSample): number {
  if (sample.symbolSize === undefined || sample.symbolSize <= 0 || sample.windowMs <= 0) {
    return 0
  }
  const delta = Math.max(0, sample.unique - prev.unique)
  const instant = (delta * sample.symbolSize) / (sample.windowMs / 1000)
  return emaBlend(prev.bytesPerSecond, instant, sample.windowMs)
}

/** Stateful projection: decodeRate is an EMA of every window seen so far. */
export function updateStats(prev: ReceiverStats, sample: StatsSample): ReceiverStats {
  const instant = instantaneousRate(sample.decodedInWindow, sample.windowMs)
  return statsOf(
    prev,
    sample,
    emaBlend(prev.decodeRate, instant, sample.windowMs),
    windowedBytesPerSecond(prev, sample),
  )
}

export type FeedAction = 'reset' | 'start' | 'feed-more' | 'none'

/** The reassembler surface handleFeedResult drives (real instance or a test fake). */
export interface ReassemblerLike {
  reset(): void
  start(metadata: Metadata, symbols: Uint8Array[], esiSet: Set<number>): Promise<void>
  feedMore(symbols: Uint8Array[], esiSet: Set<number>): void
}

/** Feed bookkeeping: whether start() ran and which esi already reached the decoder. */
export interface FeedHandleState {
  readonly started: boolean
  readonly fedEsi: ReadonlySet<number>
}

export const EMPTY_FEED_STATE: FeedHandleState = { started: false, fedEsi: new Set() }

/**
 * Applies one FrameBuffer.feed result to the reassembler. A new session resets
 * the reassembler; once metadata is known, every held symbol whose esi has not
 * been handed over yet is start()ed (first batch) or feedMore()d (the rest).
 */
export async function handleFeedResult(
  buffer: FrameBuffer,
  reassembler: ReassemblerLike,
  result: FeedResult,
  state: FeedHandleState,
): Promise<{ action: FeedAction; state: FeedHandleState }> {
  let next = state
  if (result.isNewSession === true) {
    reassembler.reset()
    next = EMPTY_FEED_STATE
  }
  const metadata = buffer.metadata
  if (result.status !== 'ok' || metadata === undefined) {
    return { action: result.isNewSession === true ? 'reset' : 'none', state: next }
  }
  const symbols = buffer.symbols()
  const esiList = [...buffer.symbolEsiSet()].sort((a, b) => a - b)
  const toFeed: Uint8Array[] = []
  const newlyFed: number[] = []
  // symbols() is esi-sorted exactly like esiList, so the index alignment holds.
  for (let i = 0; i < esiList.length; i++) {
    const esi = esiList[i]
    const payload = symbols[i]
    if (esi === undefined || payload === undefined || next.fedEsi.has(esi)) {
      continue
    }
    toFeed.push(payload)
    newlyFed.push(esi)
  }
  if (toFeed.length === 0) {
    return { action: 'none', state: next }
  }
  const fedEsi = new Set(next.fedEsi)
  for (const esi of newlyFed) {
    fedEsi.add(esi)
  }
  const fedState: FeedHandleState = { started: true, fedEsi }
  if (next.started) {
    reassembler.feedMore(toFeed, buffer.symbolEsiSet())
    return { action: 'feed-more', state: fedState }
  }
  await reassembler.start(metadata, toFeed, buffer.symbolEsiSet())
  return { action: 'start', state: fedState }
}

/**
 * Receiver orchestration shell: camera -> rAF -> downscaled canvas -> decode
 * pool -> FrameBuffer -> Reassembler -> onFile, streaming live ReceiverStats.
 *
 * All DOM, canvas, and worker access lives here. The pure stats/derived core
 * (computeStats/updateStats, downsampleTarget, estimateEta, handleFeedResult)
 * lives in stats.ts and is re-exported below so callers keep one import path.
 */

import { PROFILE_GRID } from '../protocol/constants'
import { acquireCamera, buildConstraints, readSettings, tryLockFocusExposure } from './camera'
import type { DecodeResult } from './decode'
import { FrameBuffer, type FeedResult } from './frames'
import { DecodePool, poolSize } from './pool'
import { Reassembler, ReassemblyError, type ReassemblyResult } from './reassemble'
import {
  EMPTY_FEED_STATE,
  EMPTY_STATS,
  downsampleTarget,
  handleFeedResult,
  updateStats,
  type FeedHandleState,
  type ReceiverStats,
  type ReceiverStatus,
  type StatsSample,
} from './stats'

export * from './stats'

const STATS_INTERVAL_MS = 500
const FALLBACK_FPS = 30

export interface ReceiverOrchestratorOptions {
  readonly videoEl: HTMLVideoElement
  readonly canvas: HTMLCanvasElement
  readonly onStats: (stats: ReceiverStats) => void
  readonly onFile?: (result: ReassemblyResult) => void
  readonly poolSize?: number
}

export class ReceiverOrchestrator {
  private readonly videoEl: HTMLVideoElement
  private readonly canvas: HTMLCanvasElement
  private readonly onStats: (stats: ReceiverStats) => void
  private readonly onFile: ((result: ReassemblyResult) => void) | undefined
  private readonly pool: DecodePool
  private readonly poolLimit: number
  private readonly buffer = new FrameBuffer()
  private readonly ctx: CanvasRenderingContext2D | null
  private reassembler: Reassembler
  private reassemblerSessionId: string | undefined
  private reassemblerMtu: number | undefined
  private feedState: FeedHandleState = EMPTY_FEED_STATE
  private feedQueue: Promise<void> = Promise.resolve()
  private tracks: MediaStreamTrack[] = []
  private rafId: number | undefined
  private running = false
  private status: ReceiverStatus = 'idle'
  private stats: ReceiverStats = EMPTY_STATS
  private captureWidth: number | undefined
  private captureHeight: number | undefined
  private actualFps: number | undefined
  private lastErrorMessage: string | undefined
  private sessionStartMs = 0
  private lastStatsAt = 0
  private lastDispatchAt = 0
  private decodedInWindow = 0
  private inFlight = 0
  private verified: boolean | undefined

  constructor(opts: ReceiverOrchestratorOptions) {
    this.videoEl = opts.videoEl
    this.canvas = opts.canvas
    this.onStats = opts.onStats
    this.onFile = opts.onFile
    this.poolLimit = opts.poolSize ?? poolSize()
    this.pool = new DecodePool(opts.poolSize)
    this.ctx = opts.canvas.getContext('2d', { willReadFrequently: true })
    this.reassembler = new Reassembler({ mtu: PROFILE_GRID.mtu })
  }

  get lastError(): string | undefined {
    return this.lastErrorMessage
  }

  async start(): Promise<void> {
    if (this.running) {
      return
    }
    this.running = true
    this.status = 'scanning'
    this.verified = undefined
    try {
      const stream = await acquireCamera(buildConstraints(), (track) => {
        this.tracks.push(track)
      })
      const settings = readSettings(stream)
      this.captureWidth = settings.width
      this.captureHeight = settings.height
      this.actualFps = settings.frameRate
      this.videoEl.srcObject = stream
      await this.videoEl.play()
      await tryLockFocusExposure(stream, this.videoEl)
      this.buffer.reset()
      this.reassembler.reset()
      this.feedState = EMPTY_FEED_STATE
      this.sessionStartMs = this.lastStatsAt = this.lastDispatchAt = performance.now()
      this.rafId = requestAnimationFrame(this.onRaf)
    } catch (error) {
      this.fail(error)
      throw error
    }
  }

  stop(): void {
    this.halt()
  }

  private readonly onRaf = (): void => {
    if (!this.running) {
      return
    }
    this.rafId = requestAnimationFrame(this.onRaf)
    const now = performance.now()
    if (now - this.lastStatsAt >= STATS_INTERVAL_MS) {
      this.emitStats(now - this.lastStatsAt)
      this.lastStatsAt = now
    }
    this.step(now)
  }

  private step(now: number): void {
    if (this.inFlight >= this.poolLimit) {
      return
    }
    const fps = this.actualFps !== undefined && this.actualFps > 0 ? this.actualFps : FALLBACK_FPS
    if (now - this.lastDispatchAt < 1000 / fps) {
      return
    }
    if (this.videoEl.readyState < HTMLMediaElement.HAVE_CURRENT_DATA) return
    if (this.ctx === null) {
      this.fail(new Error('2D canvas context unavailable'))
      return
    }
    const { width, height } = downsampleTarget(
      this.captureWidth ?? this.videoEl.videoWidth,
      this.captureHeight ?? this.videoEl.videoHeight,
    )
    this.canvas.width = width
    this.canvas.height = height
    this.ctx.drawImage(this.videoEl, 0, 0, width, height)
    const imageData = this.ctx.getImageData(0, 0, width, height)
    this.inFlight++
    this.lastDispatchAt = now
    this.pool
      .decode(imageData.data, width, height)
      .then((results) => this.onDecoded(results))
      .catch((error: unknown) => this.onDecodeError(error))
  }

  private onDecoded(results: DecodeResult[]): void {
    this.inFlight--
    if (results.length > 0) this.decodedInWindow++
    this.feedQueue = this.feedQueue
      .then(() => this.processResults(results))
      .catch((error: unknown) => this.fail(error))
  }

  private onDecodeError(error: unknown): void {
    this.inFlight--
    if (this.running) {
      this.fail(error)
    }
  }

  private async processResults(results: DecodeResult[]): Promise<void> {
    for (const result of results) {
      if (result.bytes === undefined) continue
      await this.handleFeed(this.buffer.feed(result.bytes))
    }
  }

  private async handleFeed(feedResult: FeedResult): Promise<void> {
    if (feedResult.isNewSession === true) {
      this.sessionStartMs = performance.now()
      this.verified = undefined
    }
    const reassembler = this.ensureReassembler()
    const { state } = await handleFeedResult(this.buffer, reassembler, feedResult, this.feedState)
    this.feedState = state
    this.status = this.buffer.k !== undefined ? 'transferring' : 'scanning'
    if (this.status === 'transferring' && reassembler.isComplete) {
      await this.completeTransfer()
    }
  }

  private ensureReassembler(): Reassembler {
    const metadata = this.buffer.metadata
    if (metadata === undefined) {
      return this.reassembler
    }
    if (this.reassemblerSessionId !== metadata.sessionId || this.reassemblerMtu !== metadata.mtu) {
      this.reassembler = new Reassembler({ mtu: metadata.mtu })
      this.reassemblerSessionId = metadata.sessionId
      this.reassemblerMtu = metadata.mtu
      this.feedState = EMPTY_FEED_STATE
    }
    return this.reassembler
  }

  private async completeTransfer(): Promise<void> {
    const result = await this.reassembler.finish()
    this.verified = true
    this.status = 'complete'
    this.onFile?.(result)
    this.onStats({ ...this.stats, status: 'complete', verified: true })
    this.halt()
  }

  private emitStats(windowMs: number): void {
    const sample: StatsSample = {
      unique: this.buffer.uniqueSymbolCount,
      k: this.buffer.k,
      totalFramesSeen: this.buffer.totalFramesSeen,
      droppedCount: this.buffer.droppedCount,
      elapsedMs: performance.now() - this.sessionStartMs,
      symbolSize: this.buffer.metadata?.symbolSize,
      decodedInWindow: this.decodedInWindow,
      windowMs,
    }
    this.decodedInWindow = 0
    const metadata = this.buffer.metadata
    const stats: ReceiverStats = {
      ...updateStats(this.stats, sample),
      status: this.status,
      metaSeen: metadata !== undefined,
      fileName: metadata?.filename,
      verified: this.verified,
    }
    this.stats = stats
    this.onStats(stats)
  }

  private fail(error: unknown): void {
    if (!this.running) {
      return
    }
    this.status = 'error'
    this.lastErrorMessage = error instanceof Error ? error.message : String(error)
    const mismatched = error instanceof ReassemblyError && error.code === 'hash-mismatch'
    this.verified = mismatched ? false : this.verified
    this.onStats({ ...this.stats, status: 'error', verified: this.verified })
    this.halt()
  }

  private halt(): void {
    this.running = false
    if (this.rafId !== undefined) cancelAnimationFrame(this.rafId)
    this.rafId = undefined
    for (const track of this.tracks) {
      track.stop()
    }
    this.tracks = []
    this.pool.dispose()
  }
}

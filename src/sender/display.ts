/**
 * Sender broadcast display loop: renders a continuously-cycling set of QR
 * codes on a fullscreen canvas — the "no start/end point, keep showing QRs"
 * core of the app. No network, no start/stop sequencing: it broadcasts forever
 * until {@link SenderDisplay.stop} or {@link SenderDisplay.dispose}.
 *
 * QR content is the COMPLETE wire frame bytes (30-byte header + payload +
 * CRC32C), not the decoded RaptorQ payload: the receiver reads each QR with
 * zxing and feeds exactly those bytes to FrameBuffer.feed → decodeFrame, so
 * encoding anything less would make every QR undecodable on the receive side.
 * The pipeline's frames already fit their bytes-per-tile QR capacity, so
 * encodeQrBytes only throws on an integration bug — which the loop converts
 * into a skipped tile + dropped-tick count.
 *
 * Geometry is layout-aware: the settings' layout (single/column3/row3/grid4/
 * grid9) divides the full canvas into cols×rows cells sized by
 * {@link computeLayoutGeometry}, and the canvas backing store is sized to the
 * display resolution (device pixels) and CSS-scaled to the viewport, so every
 * module lands on an integer number of physical pixels.
 */

import {
  BYTES_PER_TILE,
  LAYOUTS,
  METADATA_REBROADCAST_EVERY,
  type LayoutId,
  type TransferSettings,
} from '../protocol/constants'
import { encodeQrBytes, type QrMatrix } from '../qr/encode'
import { MIN_QUIET_ZONE, renderTiles } from '../qr/render'
import { releaseWakeLock, requestWakeLock } from './controls'
import {
  FramePool,
  adaptFps,
  computeFrameDelayMs,
  computeLayoutGeometry,
  nextEsiRoundRobin,
  resolvePacing,
  type DisplayFrame,
  type SenderStats,
} from './pacing'
import type { PreparedTransfer } from './pipeline'

export interface SenderDisplayOptions {
  readonly canvas: HTMLCanvasElement
  readonly prepared: PreparedTransfer
  /** Must match prepared.info.settings.bytesPerTile — frames are sized for this symbol. */
  readonly settings: TransferSettings
  /** Called every ~500ms with broadcast stats for the overlay. */
  readonly onStats?: (stats: SenderStats) => void
}

export class SenderDisplay {
  private readonly canvas: HTMLCanvasElement
  private readonly ctx: CanvasRenderingContext2D
  private readonly prepared: PreparedTransfer
  private readonly settings: TransferSettings
  private readonly layout: LayoutId
  private readonly tilesPerFrame: number
  private readonly version: number
  private readonly quietZone = MIN_QUIET_ZONE
  private readonly pool: FramePool
  private readonly onStats: ((stats: SenderStats) => void) | undefined

  private currentFps: number
  private rafId: number | undefined
  private renderedTicks = 0
  private failedTicks = 0
  private lastRenderTime = 0
  private startTime = 0
  private lastStatsTime = 0
  private lastStatsTickCount = 0
  private lastFrame: DisplayFrame | undefined
  private ppm = 1

  constructor(opts: SenderDisplayOptions) {
    const ctx = opts.canvas.getContext('2d')
    if (ctx === null) {
      throw new Error('SenderDisplay: 2d canvas context unavailable')
    }
    if (opts.settings.bytesPerTile !== opts.prepared.info.settings.bytesPerTile) {
      throw new TypeError(
        `SenderDisplay bytesPerTile ${opts.settings.bytesPerTile} does not match prepared ` +
          `transfer ${opts.prepared.info.settings.bytesPerTile}`,
      )
    }
    this.canvas = opts.canvas
    this.ctx = ctx
    this.prepared = opts.prepared
    this.settings = opts.settings
    this.layout = opts.settings.layout
    this.pool = new FramePool(opts.prepared)
    this.onStats = opts.onStats

    const bpt = BYTES_PER_TILE[this.settings.bytesPerTile]
    this.version = bpt.version
    this.tilesPerFrame = LAYOUTS[this.layout].cols * LAYOUTS[this.layout].rows
    // effectiveFps is layout/canvas-size independent, so the pre-start canvas
    // dims (defaults at construction) do not skew the initial pacing.
    this.currentFps = resolvePacing(
      this.settings,
      this.canvas.width,
      this.canvas.height,
    ).effectiveFps
  }

  /** Begins the rAF broadcast loop. Idempotent. */
  start(): void {
    if (this.rafId !== undefined) {
      return
    }
    this.sizeCanvasToDisplay()
    this.updateGeometry()
    const now = performance.now()
    this.startTime = now
    this.lastRenderTime = now
    this.lastStatsTime = now
    this.rafId = requestAnimationFrame(this.tick)
  }

  /** Cancels the rAF loop. The encoder stays alive (see {@link dispose}). */
  stop(): void {
    if (this.rafId === undefined) {
      return
    }
    cancelAnimationFrame(this.rafId)
    this.rafId = undefined
  }

  /** Stops the loop and releases the RaptorQ encoder. Call once when done. */
  dispose(): void {
    this.stop()
    this.prepared.encoder.dispose()
  }

  /** Number of frames actually rendered since start(). */
  get tickCount(): number {
    return this.renderedTicks
  }

  /** Frames (or tiles) skipped because encoding failed. */
  get droppedTicks(): number {
    return this.failedTicks
  }

  /** Measured fps over the whole run: tickCount / elapsed seconds. */
  get measuredFps(): number {
    const elapsedMs = performance.now() - this.startTime
    return elapsedMs > 0 ? (this.renderedTicks / elapsedMs) * 1000 : 0
  }

  /** The most recently rendered frame (testable seam for the e2e specs). */
  get lastRenderedFrame(): DisplayFrame | undefined {
    return this.lastFrame
  }

  /**
   * Screen-awake boost: keeps the screen on via the wake lock. Brightness
   * itself has no standard API — the overlay tells the user to raise it.
   */
  setBoost(active: boolean): void {
    if (active) {
      void requestWakeLock()
    } else {
      void releaseWakeLock()
    }
  }

  private readonly tick = (now: number): void => {
    if (this.rafId === undefined) {
      return // stopped between frames
    }
    const frameDelayMs = computeFrameDelayMs(this.currentFps)
    if (now - this.lastRenderTime < frameDelayMs) {
      // Display refresh arrived early — wait for the next cycle (keeps fps at
      // or below the target so QRs phase-drift across camera captures).
      this.rafId = requestAnimationFrame(this.tick)
      return
    }
    this.lastRenderTime = now

    const workStart = performance.now()
    this.renderFrame(this.renderedTicks)
    this.renderedTicks++
    const workMs = performance.now() - workStart
    this.currentFps = adaptFps(this.currentFps, workMs, frameDelayMs)
    this.emitStatsIfDue(now)
    this.rafId = requestAnimationFrame(this.tick)
  }

  private renderFrame(frameIndex: number): void {
    // Every METADATA_REBROADCAST_EVERY ticks one data tile becomes the META
    // frame (slot 0) so receivers joining mid-broadcast learn session + file
    // metadata without the data stream ever pausing.
    const showMeta = frameIndex % METADATA_REBROADCAST_EVERY === 0
    const dataTiles = showMeta ? this.tilesPerFrame - 1 : this.tilesPerFrame
    const esis = nextEsiRoundRobin(this.pool.k, this.pool.repairAvailable, frameIndex, dataTiles)

    const tiles: (QrMatrix | null)[] = []
    if (showMeta) {
      tiles.push(this.encodeFrame(this.prepared.metaFrames[0]))
    }
    for (const esi of esis) {
      tiles.push(this.encodeFrame(this.pool.frameBytes(esi)))
    }

    const { cols, rows } = LAYOUTS[this.layout]
    const imageData = renderTiles(tiles, {
      cols,
      rows,
      modules: this.ppm,
      quietZone: this.quietZone,
      canvasWidth: this.canvas.width,
      canvasHeight: this.canvas.height,
    })

    // renderTiles allocates a fresh ArrayBuffer and fully covers the canvas,
    // so the clamped view is zero-copy over the same bytes — non-square is fine.
    const buffer = imageData.buffer as ArrayBuffer
    const rgba = new Uint8ClampedArray(buffer, imageData.byteOffset, imageData.byteLength)
    this.ctx.putImageData(new ImageData(rgba, this.canvas.width, this.canvas.height), 0, 0)

    this.lastFrame = {
      imageData,
      canvasSize: Math.min(this.canvas.width, this.canvas.height),
      frameIndex,
      esis,
    }
  }

  private encodeFrame(frameBytes: Uint8Array | undefined): QrMatrix | null {
    if (frameBytes === undefined) {
      this.failedTicks++
      return null
    }
    try {
      return encodeQrBytes(frameBytes, { version: this.version })
    } catch {
      this.failedTicks++
      return null
    }
  }

  private emitStatsIfDue(now: number): void {
    if (this.onStats === undefined || now - this.lastStatsTime < 500) {
      return
    }
    const dtMs = now - this.lastStatsTime
    const dtTicks = this.renderedTicks - this.lastStatsTickCount
    this.onStats({
      tickCount: this.renderedTicks,
      fps: dtMs > 0 ? Math.round((dtTicks / dtMs) * 1000 * 10) / 10 : 0,
      droppedTicks: this.failedTicks,
      avgTickMs:
        this.renderedTicks > 0
          ? Math.round(((now - this.startTime) / this.renderedTicks) * 10) / 10
          : 0,
      layout: this.layout,
      k: this.pool.k,
    })
    this.lastStatsTime = now
    this.lastStatsTickCount = this.renderedTicks
  }

  /** Backing store = display resolution (device pixels); CSS scales to viewport. */
  private sizeCanvasToDisplay(): void {
    const dpr = typeof window === 'undefined' ? 1 : window.devicePixelRatio || 1
    this.canvas.width = Math.round(window.innerWidth * dpr)
    this.canvas.height = Math.round(window.innerHeight * dpr)
  }

  /** Layout cells split the full canvas; ppm keeps every module at integer px. */
  private updateGeometry(): void {
    this.ppm = computeLayoutGeometry(
      this.canvas.width,
      this.canvas.height,
      this.layout,
      this.version,
      this.quietZone,
    ).ppm
  }
}

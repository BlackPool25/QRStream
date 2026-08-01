/**
 * Sender broadcast pacing + packet scheduling — DOM-free so it runs under the
 * Node test runner. The display loop (sender/display.ts) consumes these to keep
 * the broadcast's frame rate disciplined: display fps must stay BELOW the
 * camera's capture fps (so QR refreshes phase-drift across capture frames
 * instead of aliasing), and each frame must get ≥2 display refresh cycles.
 */

import { repairFrames, type PreparedTransfer } from './pipeline'
import {
  BYTES_PER_TILE,
  LAYOUTS,
  METADATA_REBROADCAST_EVERY,
  type LayoutId,
  type TransferSettings,
} from '../protocol/constants'
import { MIN_QUIET_ZONE, integerScalePx } from '../qr/render'

/**
 * Fps ceiling per layout: the 3×3 grid is render-heavy (9 tiles/frame) so it
 * caps at 24; the others may run up to 30 when the device and display allow.
 */
export const LAYOUT_MAX_FPS: Readonly<Record<LayoutId, number>> = {
  single: 30,
  column3: 30,
  row3: 30,
  grid4: 30,
  grid9: 24,
}

/** Min square-canvas side (px) at which the 2×2 grid is worthwhile. */
export const GRID4_MIN_CANVAS_PX = 800

/** Min square-canvas side (px) at which the 3×3 grid is worthwhile. */
export const GRID9_MIN_CANVAS_PX = 1800

/**
 * Fps ceiling for the grid profile (4×V27 tiles): at 60Hz capture this keeps
 * every QR visible across ≥2 camera frames while staying under capture fps.
 * Legacy — the display loop still reads it until T6 migrates to resolvePacing.
 */
export const GRID_MAX_FPS = 24

/** Fps ceiling for the single-V40 profile — same discipline, bigger symbol. */
export const V40_MAX_FPS = 12

/** Hard floor the display loop throttles down to before giving up on fps. */
export const MIN_FPS = 8

/** Default encode+render margin over the frame delay used by {@link renderBudgetOk}. */
export const DEFAULT_OVERHEAD_FACTOR = 1.5

/** Extra repair symbols generated lazily beyond k: ceil(k * 0.3) + 100. */
export const REPAIR_EXTRA_FACTOR = 0.3
export const REPAIR_EXTRA_MIN = 100

/** How far a single over-budget tick steps the target fps down (min MIN_FPS). */
export const FPS_ADAPT_STEP = 4

/** Stats handed to the overlay roughly every 500ms. */
export interface SenderStats {
  readonly tickCount: number
  readonly fps: number
  readonly droppedTicks: number
  readonly avgTickMs: number
  readonly layout: LayoutId
  readonly k: number
}

/** One rendered broadcast frame (RGBA imageData + the esis it showed). */
export interface DisplayFrame {
  readonly imageData: Uint8Array
  readonly canvasSize: number
  readonly frameIndex: number
  readonly esis: number[]
}

/** Frame delay for a target fps, rounded to the nearest millisecond. */
export function computeFrameDelayMs(targetFps: number): number {
  return Math.round(1000 / targetFps)
}

/**
 * Layout best suited to the canvas aspect ratio and size: extreme portrait →
 * column3, extreme landscape → row3, square-ish canvases by how many
 * near-square tiles they can hold (grid9 needs both sides >= GRID9_MIN_CANVAS_PX,
 * grid4 >= GRID4_MIN_CANVAS_PX), otherwise a single tile.
 */
export function suggestLayout(canvasWidth: number, canvasHeight: number): LayoutId {
  const aspect = canvasWidth / canvasHeight
  if (aspect < 0.8) {
    return 'column3'
  }
  if (aspect > 1.25) {
    return 'row3'
  }
  const minSide = Math.min(canvasWidth, canvasHeight)
  if (minSide >= GRID9_MIN_CANVAS_PX) {
    return 'grid9'
  }
  if (minSide >= GRID4_MIN_CANVAS_PX) {
    return 'grid4'
  }
  return 'single'
}

/** Effective fps ceiling for a transfer: layout cap AND display-refresh cap. */
function effectiveFpsFor(settings: TransferSettings): number {
  const fpsCeiling = Math.min(LAYOUT_MAX_FPS[settings.layout], settings.highRefresh ? 30 : 24)
  return Math.min(settings.targetFps, fpsCeiling)
}

/** Pacing decision for one transfer on one canvas: tiles, fps caps, suggested layout. */
export function resolvePacing(
  settings: TransferSettings,
  canvasWidth: number,
  canvasHeight: number,
): { tilesPerFrame: number; fpsCeiling: number; effectiveFps: number; suggestedLayout: LayoutId } {
  const layout = LAYOUTS[settings.layout]
  const fpsCeiling = Math.min(LAYOUT_MAX_FPS[settings.layout], settings.highRefresh ? 30 : 24)
  return {
    tilesPerFrame: layout.cols * layout.rows,
    fpsCeiling,
    effectiveFps: Math.min(settings.targetFps, fpsCeiling),
    suggestedLayout: suggestLayout(canvasWidth, canvasHeight),
  }
}

/** Per-cell pixel geometry for a layout on a canvas, with an integer ppm. */
export function computeLayoutGeometry(
  canvasWidth: number,
  canvasHeight: number,
  layout: LayoutId,
  version: number,
  quietZone: number = MIN_QUIET_ZONE,
): { cellW: number; cellH: number; ppm: number } {
  const { cols, rows } = LAYOUTS[layout]
  const cellW = Math.floor(canvasWidth / cols)
  const cellH = Math.floor(canvasHeight / rows)
  const ppm = integerScalePx(version * 4 + 17 + 2 * quietZone, Math.min(cellW, cellH))
  return { cellW, cellH, ppm }
}

/**
 * Expected broadcast rate in bytes/second: effective fps × data tiles per
 * tick × symbol size. One of every 32 ticks is the metadata re-broadcast, so
 * data tiles per tick = tilesPerFrame − 1/32; repair overhead (~1.0×) is a
 * transfer-level cost and is not subtracted here.
 */
export function estimateThroughput(settings: TransferSettings): number {
  const layout = LAYOUTS[settings.layout]
  const tilesPerFrame = layout.cols * layout.rows
  const symbolSize = BYTES_PER_TILE[settings.bytesPerTile].symbolSize
  return effectiveFpsFor(settings) * (tilesPerFrame - 1 / METADATA_REBROADCAST_EVERY) * symbolSize
}

/** Expected wall time to broadcast `compressedSize` bytes at the estimated rate. */
export function estimateEtaSeconds(settings: TransferSettings, compressedSize: number): number {
  return compressedSize / estimateThroughput(settings)
}

/**
 * Whether measured encode+render work (`encodeMs`) fits inside one frame delay
 * with an overhead margin (default 1.5×) — the budget check the loop uses to
 * decide when to throttle the frame rate down.
 */
export function renderBudgetOk(
  encodeMs: number,
  frameDelayMs: number,
  overheadFactor: number = DEFAULT_OVERHEAD_FACTOR,
): boolean {
  return encodeMs * overheadFactor <= frameDelayMs
}

/**
 * Steps the frame rate down by {@link FPS_ADAPT_STEP} when encode+render
 * overran the frame budget, floored at {@link MIN_FPS}. Monotonic — a device
 * that falls behind stays throttled, so the broadcast rate stays stable.
 */
export function adaptFps(currentFps: number, workMs: number, frameDelayMs: number): number {
  return renderBudgetOk(workMs, frameDelayMs)
    ? currentFps
    : Math.max(MIN_FPS, currentFps - FPS_ADAPT_STEP)
}

/**
 * Deterministic round-robin pick of `tilesPerFrame` packet indices to show on
 * a tick. The pool is the k source esis 0..k-1 followed by the `repairAvailable`
 * repair esis k..k+repairAvailable-1; frame `frameIndex` starts at
 * `frameIndex * tilesPerFrame` mod pool size and walks forward, so consecutive
 * frames never repeat within a frame and the whole pool is covered before the
 * sequence wraps. No randomness — the broadcast pattern is a pure function of
 * frameIndex, which is what lets receivers join mid-broadcast and see a steady
 * stream of distinct packets.
 */
export function nextEsiRoundRobin(
  k: number,
  repairAvailable: number,
  frameIndex: number,
  tilesPerFrame: number,
): number[] {
  const poolSize = k + repairAvailable
  if (poolSize <= 0) {
    return []
  }
  const start = (frameIndex * tilesPerFrame) % poolSize
  const esis: number[] = []
  for (let i = 0; i < tilesPerFrame; i++) {
    esis.push((start + i) % poolSize)
  }
  return esis
}

/**
 * Deterministic packet source for the broadcast loop: source frames come
 * straight from the prepared transfer; repair frames are generated lazily in
 * one batch on first use and cached until the round-robin wraps back to source
 * (the first repair tick pays a one-time cost, every later repair esi is free).
 */
export class FramePool {
  private readonly prepared: PreparedTransfer
  /** The k source symbols. */
  readonly k: number
  private repairCache: Uint8Array[] | undefined

  constructor(prepared: PreparedTransfer) {
    this.prepared = prepared
    this.k = prepared.info.k
  }

  /** Repair symbols available beyond k: ceil(k * 0.3) + 100. */
  get repairAvailable(): number {
    return Math.ceil(this.k * REPAIR_EXTRA_FACTOR) + REPAIR_EXTRA_MIN
  }

  /** Full wire-frame bytes for esi; esi ≥ k resolves into the repair cache. */
  frameBytes(esi: number): Uint8Array {
    if (esi < this.k) {
      const frame = this.prepared.dataFrames[esi]
      if (frame === undefined) {
        throw new RangeError(`source frame esi ${esi} missing`)
      }
      return frame
    }
    const repairIdx = esi - this.k
    if (this.repairCache === undefined) {
      this.repairCache = repairFrames(this.prepared, this.repairAvailable)
    }
    const repair = this.repairCache[repairIdx]
    if (repair === undefined) {
      throw new RangeError(`repair frame esi ${esi} missing`)
    }
    return repair
  }
}

/**
 * Sender broadcast pacing + packet scheduling — DOM-free so it runs under the
 * Node test runner. The display loop (sender/display.ts) consumes these to keep
 * the broadcast's frame rate disciplined: display fps must stay BELOW the
 * camera's capture fps (so QR refreshes phase-drift across capture frames
 * instead of aliasing), and each frame must get ≥2 display refresh cycles.
 */

import { repairFrames, type PreparedTransfer } from './pipeline'

/** Square canvas side (px) at which the 2×2 grid profile beats the single V40 tile. */
export const GRID_MIN_CANVAS_PX = 1600

/**
 * Fps ceiling for the grid profile (4×V27 tiles): at 60Hz capture this keeps
 * every QR visible across ≥2 camera frames while staying under capture fps.
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
  readonly profile: 'grid' | 'v40'
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

export interface ProfileChoice {
  readonly profile: 'grid' | 'v40'
  readonly tilesPerFrame: number
  /** Broadcast fps ceiling = min(requested target, the profile's own cap). */
  readonly maxFramesPerSecond: number
}

/**
 * Picks the display profile from the square canvas side available for QRs:
 * the 2×2 grid needs ~1600px (4×V27 tiles at integer 6px/module land in two
 * 800px quadrants); smaller canvases fall back to one V40 tile.
 */
export function chooseProfile(targetFps: number, canvasSize: number): ProfileChoice {
  if (canvasSize >= GRID_MIN_CANVAS_PX) {
    return {
      profile: 'grid',
      tilesPerFrame: 4,
      maxFramesPerSecond: Math.min(targetFps, GRID_MAX_FPS),
    }
  }
  return {
    profile: 'v40',
    tilesPerFrame: 1,
    maxFramesPerSecond: Math.min(targetFps, V40_MAX_FPS),
  }
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

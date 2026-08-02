/**
 * Sender transfer settings: defaults, validation, display refresh-rate
 * detection and human-readable labels. All DOM access is confined to the
 * browser wrappers so the core logic (validateSettings,
 * detectRefreshRateCore, transferLabel) runs under the Node test runner.
 */

import { BYTES_PER_TILE, LAYOUTS, type TransferSettings } from '../protocol/constants'

/** Browser window augmented with the refresh-rate override test hook. */
export interface QrWindow extends Window {
  __qrRefreshRateOverride?: number
}

export const DEFAULT_TRANSFER_SETTINGS: TransferSettings = {
  bytesPerTile: '1k',
  layout: 'grid4',
  targetFps: 15,
  highRefresh: false,
}

const BYTES_PER_TILE_IDS = ['1k', '2k', '2.5k'] as const
const TARGET_FPS_VALUES: readonly number[] = [12, 15, 24, 30]

/**
 * Validates a settings object at the UI/pipeline boundary, throwing TypeError
 * on unknown enum values, a disallowed targetFps or a non-boolean
 * highRefresh. Callers may trust the typed settings afterwards.
 */
export function validateSettings(s: TransferSettings): void {
  if (!BYTES_PER_TILE_IDS.includes(s.bytesPerTile)) {
    throw new TypeError(
      `bytesPerTile must be one of ${BYTES_PER_TILE_IDS.join(', ')}, got ${String(s.bytesPerTile)}`,
    )
  }
  if (!Object.keys(LAYOUTS).includes(s.layout)) {
    throw new TypeError(
      `layout must be one of ${Object.keys(LAYOUTS).join(', ')}, got ${String(s.layout)}`,
    )
  }
  if (!TARGET_FPS_VALUES.includes(s.targetFps)) {
    throw new TypeError(
      `targetFps must be one of ${TARGET_FPS_VALUES.join(', ')}, got ${s.targetFps}`,
    )
  }
  if (typeof s.highRefresh !== 'boolean') {
    throw new TypeError(`highRefresh must be a boolean, got ${typeof s.highRefresh}`)
  }
}

/**
 * DOM-free refresh-rate probe: counts rAF callbacks over a `windowMs` window
 * and classifies the measured rate (>=105 → 120, >=75 → 90, else 60; an
 * elapsed of 0 resolves 60). Always resolves and cancels the trailing
 * pending rAF so the probe leaves no orphaned frame.
 */
export function detectRefreshRateCore(
  raf: (cb: FrameRequestCallback) => number,
  cancel: (id: number) => void,
  now: () => number,
  windowMs = 400,
): Promise<number> {
  return new Promise((resolve) => {
    const start = now()
    let ticks = 0
    let lastId = 0

    const frame: FrameRequestCallback = () => {
      const elapsed = now() - start
      ticks += 1
      // Register the next frame up front so the trailing pending one can be
      // canceled when the window closes.
      lastId = raf(frame)
      if (elapsed <= 0) {
        cancel(lastId)
        resolve(60)
        return
      }
      if (elapsed < windowMs) return
      cancel(lastId)
      const rate = (ticks * 1000) / elapsed
      resolve(rate >= 105 ? 120 : rate >= 75 ? 90 : 60)
    }

    lastId = raf(frame)
  })
}

/**
 * Browser wrapper around {@link detectRefreshRateCore}. Honors the
 * `__qrRefreshRateOverride` test hook (set to a number to bypass probing) and
 * resolves 60 when no window exists (SSR).
 */
export async function detectRefreshRate(): Promise<number> {
  if (typeof window === 'undefined') return 60
  const override = (window as QrWindow).__qrRefreshRateOverride
  if (typeof override === 'number') return override
  return detectRefreshRateCore(
    (cb) => window.requestAnimationFrame(cb),
    (id) => window.cancelAnimationFrame(id),
    () => performance.now(),
  )
}

/** Viewport orientation, defaulting to landscape when there is no window. */
export function detectOrientation(): 'portrait' | 'landscape' {
  if (typeof window === 'undefined') return 'landscape'
  return window.innerHeight > window.innerWidth ? 'portrait' : 'landscape'
}

/** Human-readable transfer label, e.g. "V27 · 2×2". */
export function transferLabel(settings: TransferSettings): string {
  const tile = BYTES_PER_TILE[settings.bytesPerTile]
  const layout = LAYOUTS[settings.layout]
  return `V${tile.version} · ${layout.rows}×${layout.cols}`
}

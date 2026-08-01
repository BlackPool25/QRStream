/**
 * Sender overlay helpers: how large one QR module renders on the canvas, the
 * viewing-distance guidance the overlay shows, and the screen-awake boost.
 * Pure and DOM-free (browser globals are guarded), so all of it is
 * Node-testable.
 */

import { MIN_QUIET_ZONE, integerScalePx } from '../qr/render'

let wakeLockSentinel: WakeLockSentinel | undefined

/**
 * Best-effort keep-screen-awake via the Screen Wake Lock API. No-op when the
 * API is absent (the caller's UI still instructs the user to raise brightness —
 * there is no standard API for that).
 */
export async function requestWakeLock(): Promise<void> {
  if (typeof navigator === 'undefined' || navigator.wakeLock?.request === undefined) {
    return
  }
  try {
    wakeLockSentinel = await navigator.wakeLock.request('screen')
  } catch {
    // Best-effort: browsers without the API keep the current behavior.
  }
}

/** Releases the wake lock acquired by {@link requestWakeLock}, if any. */
export async function releaseWakeLock(): Promise<void> {
  if (wakeLockSentinel === undefined) {
    return
  }
  try {
    await wakeLockSentinel.release()
  } catch {
    // Best-effort.
  }
  wakeLockSentinel = undefined
}

/**
 * Integer pixels per QR module when `version` is rendered into a
 * `canvasPx`-square area. For the grid profile pass the quadrant size
 * (canvasSize/2 — four tiles share the square); for the single-V40 profile
 * pass the full canvasSize. Mirrors {@link integerScalePx} over the complete
 * module count including the quiet zone on each side (a V27 side is
 * 27*4+17 = 125 modules, plus 2×quietZone).
 */
export function computePxPerModule(
  canvasPx: number,
  version: number,
  quietZone: number = MIN_QUIET_ZONE,
): number {
  return integerScalePx(version * 4 + 17 + 2 * quietZone, canvasPx)
}

/**
 * Viewing-distance guidance for the overlay, derived from how large a module
 * renders on screen: a module of `pxPerModule` CSS px on a typical ~0.14 mm/px
 * phone screen is comfortably readable at roughly 14 cm per px/module, with a
 * ±15 cm band that keeps the guidance honest about phone-to-phone variance.
 */
export function recommendDistance(pxPerModule: number): string {
  const centerCm = pxPerModule * 14
  const near = Math.max(10, Math.round((centerCm - 15) / 5) * 5)
  const far = Math.min(200, Math.round((centerCm + 15) / 5) * 5)
  return `hold ~${near}-${far}cm away`
}

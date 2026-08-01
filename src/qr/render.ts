import type { QrMatrix } from './encode'

export interface RenderOpts {
  /** Pixels per QR module. Use {@link integerScalePx} to keep modules crisp. */
  modules: number
  /** Quiet zone width in modules. QR spec minimum is 4. */
  quietZone?: number
  /** Square canvas side length in pixels. */
  canvasSize: number
}

/** QR spec minimum quiet zone, in modules. Violating it hurts decode. */
export const MIN_QUIET_ZONE = 4

/**
 * Integer pixels per module (floored) so modules stay crisp — sub-pixel
 * scaling anti-aliases modules and lowers decode reliability.
 */
export function integerScalePx(modules: number, targetPx: number): number {
  return Math.max(1, Math.floor(targetPx / modules))
}

function drawTile(
  frame: Uint8Array,
  canvasSize: number,
  ox: number,
  oy: number,
  matrix: QrMatrix,
  tileSidePx: number,
  ppm: number,
  quietZone: number,
): void {
  for (let y = 0; y < tileSidePx; y++) {
    for (let x = 0; x < tileSidePx; x++) {
      const mx = Math.floor(x / ppm) - quietZone
      const my = Math.floor(y / ppm) - quietZone
      const dark =
        mx >= 0 &&
        my >= 0 &&
        mx < matrix.size &&
        my < matrix.size &&
        (matrix.modules[my * matrix.size + mx] ?? 0) === 1
      const v = dark ? 0 : 255
      const i = ((oy + y) * canvasSize + (ox + x)) * 4
      frame[i] = v
      frame[i + 1] = v
      frame[i + 2] = v
      frame[i + 3] = 255
    }
  }
}

function fillQuadrant(
  frame: Uint8Array,
  canvasSize: number,
  qx: number,
  qy: number,
  quadW: number,
  quadH: number,
): void {
  for (let y = 0; y < quadH; y++) {
    for (let x = 0; x < quadW; x++) {
      const i = ((qy + y) * canvasSize + (qx + x)) * 4
      frame[i] = 0
      frame[i + 1] = 0
      frame[i + 2] = 0
      frame[i + 3] = 255
    }
  }
}

function tileSidePx(matrix: QrMatrix, quietZone: number, ppm: number): number {
  return (matrix.size + quietZone * 2) * ppm
}

/**
 * Compose up to 4 QR matrices into one 2×2 display frame of RGBA bytes
 * (canvasSize × canvasSize × 4). Tile `i` occupies quadrant `i` (0 = top-left,
 * 1 = top-right, 2 = bottom-left, 3 = bottom-right), centered with a
 * `quietZone`-module margin; `null` tiles render as a solid black quadrant.
 */
export function renderGrid(matrices: (QrMatrix | null)[], opts: RenderOpts): Uint8Array {
  if (matrices.length < 1 || matrices.length > 4) {
    throw new RangeError(`renderGrid expects 1..4 tiles, got ${matrices.length}`)
  }
  const { modules: ppm, canvasSize } = opts
  const quietZone = opts.quietZone ?? MIN_QUIET_ZONE
  const frame = new Uint8Array(canvasSize * canvasSize * 4).fill(255)
  const quadW = Math.floor(canvasSize / 2)
  const quadH = Math.floor(canvasSize / 2)
  for (let i = 0; i < matrices.length; i++) {
    const qx = (i % 2) * quadW
    const qy = Math.floor(i / 2) * quadH
    const matrix = matrices[i]
    if (matrix === null || matrix === undefined) {
      fillQuadrant(frame, canvasSize, qx, qy, quadW, quadH)
      continue
    }
    const tileSide = tileSidePx(matrix, quietZone, ppm)
    if (tileSide > quadW || tileSide > quadH) {
      throw new RangeError(`tile of ${tileSide}px does not fit in a ${quadW}x${quadH} quadrant`)
    }
    drawTile(
      frame,
      canvasSize,
      qx + Math.floor((quadW - tileSide) / 2),
      qy + Math.floor((quadH - tileSide) / 2),
      matrix,
      tileSide,
      ppm,
      quietZone,
    )
  }
  return frame
}

/**
 * Render one QR matrix centered on the full canvas (v40 profile) as RGBA
 * bytes (canvasSize × canvasSize × 4).
 */
export function renderSingle(matrix: QrMatrix, opts: RenderOpts): Uint8Array {
  const { modules: ppm, canvasSize } = opts
  const quietZone = opts.quietZone ?? MIN_QUIET_ZONE
  const tileSide = tileSidePx(matrix, quietZone, ppm)
  if (tileSide > canvasSize) {
    throw new RangeError(
      `tile of ${tileSide}px does not fit in a ${canvasSize}x${canvasSize} canvas`,
    )
  }
  const frame = new Uint8Array(canvasSize * canvasSize * 4).fill(255)
  const ox = Math.floor((canvasSize - tileSide) / 2)
  drawTile(frame, canvasSize, ox, ox, matrix, tileSide, ppm, quietZone)
  return frame
}

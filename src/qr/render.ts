import type { QrMatrix } from './encode'

export interface RenderOpts {
  /** Pixels per QR module. Use {@link integerScalePx} to keep modules crisp. */
  modules: number
  /** Quiet zone width in modules. QR spec minimum is 4. */
  quietZone?: number
  /** Square canvas side length in pixels. */
  canvasSize: number
}

export interface RenderTilesOpts {
  /** Pixels per QR module. Use {@link integerScalePx} to keep modules crisp. */
  modules: number
  /** Grid columns. */
  cols: number
  /** Grid rows. */
  rows: number
  /** Quiet zone width in modules. QR spec minimum is 4. */
  quietZone?: number
  /** Canvas width in pixels. May differ from {@link canvasHeight} (landscape/portrait). */
  canvasWidth: number
  /** Canvas height in pixels. Defaults to {@link canvasWidth} (square). */
  canvasHeight?: number
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

/**
 * Rasterize one QR tile (per-pixel module lookup with a quiet-zone margin)
 * into `frame` at (ox, oy). `canvasWidth` is the frame row stride, so
 * rectangular canvases work.
 */
function drawTile(
  frame: Uint8Array,
  canvasWidth: number,
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
      const i = ((oy + y) * canvasWidth + (ox + x)) * 4
      frame[i] = v
      frame[i + 1] = v
      frame[i + 2] = v
      frame[i + 3] = 255
    }
  }
}

/** Fill a w×h cell at (ox, oy) with opaque black (null tiles). */
function fillCell(
  frame: Uint8Array,
  canvasWidth: number,
  ox: number,
  oy: number,
  w: number,
  h: number,
): void {
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = ((oy + y) * canvasWidth + (ox + x)) * 4
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
 * Compose 1..cols×rows QR matrices into a grid of RGBA bytes
 * (canvasWidth × canvasHeight × 4, white background). Tile `i` sits in cell
 * (col = i % cols, row = floor(i / cols)), centered with a `quietZone`-module
 * margin; `null`/`undefined` tiles render as a solid black cell. `canvasHeight`
 * defaults to `canvasWidth` (square).
 */
export function renderTiles(matrices: (QrMatrix | null)[], opts: RenderTilesOpts): Uint8Array {
  const { modules: ppm, cols, rows, canvasWidth } = opts
  const quietZone = opts.quietZone ?? MIN_QUIET_ZONE
  const canvasHeight = opts.canvasHeight ?? canvasWidth
  const cellCount = cols * rows
  if (matrices.length < 1 || matrices.length > cellCount) {
    throw new RangeError(`renderTiles expects 1..${cellCount} tiles, got ${matrices.length}`)
  }
  const frame = new Uint8Array(canvasWidth * canvasHeight * 4).fill(255)
  const cellW = Math.floor(canvasWidth / cols)
  const cellH = Math.floor(canvasHeight / rows)
  for (let i = 0; i < matrices.length; i++) {
    const matrix = matrices[i]
    const ox = (i % cols) * cellW
    const oy = Math.floor(i / cols) * cellH
    if (matrix === null || matrix === undefined) {
      fillCell(frame, canvasWidth, ox, oy, cellW, cellH)
      continue
    }
    const tileSide = tileSidePx(matrix, quietZone, ppm)
    if (tileSide > cellW || tileSide > cellH) {
      throw new RangeError(`tile of ${tileSide}px does not fit in a ${cellW}x${cellH} cell`)
    }
    drawTile(
      frame,
      canvasWidth,
      ox + Math.floor((cellW - tileSide) / 2),
      oy + Math.floor((cellH - tileSide) / 2),
      matrix,
      tileSide,
      ppm,
      quietZone,
    )
  }
  return frame
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
  return renderTiles(matrices, {
    cols: 2,
    rows: 2,
    modules: ppm,
    quietZone,
    canvasWidth: canvasSize,
  })
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
  return renderTiles([matrix], {
    cols: 1,
    rows: 1,
    modules: ppm,
    quietZone,
    canvasWidth: canvasSize,
  })
}

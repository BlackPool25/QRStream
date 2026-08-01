import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { beforeAll, describe, expect, it } from 'vitest'
import { prepareZXingModule, readBarcodes, type ReadResult } from 'zxing-wasm'
import {
  DataTooLongError,
  encodeQrBytes,
  fitVersion,
  GRID_CAPACITY,
  GRID_VERSION,
  MAX_CAPACITY,
} from '../../src/qr/encode'
import {
  integerScalePx,
  MIN_QUIET_ZONE,
  renderGrid,
  renderSingle,
  renderTiles,
} from '../../src/qr/render'

// Node builtin type shims for the zxing wasm loader live in node-shims.d.ts.

// ── deterministic pseudo-random payloads (LCG, no Math.random) ────────────

function pseudoRandomBytes(n: number, seed = 0x5eed_1234): Uint8Array {
  const out = new Uint8Array(n)
  let s = seed >>> 0
  for (let i = 0; i < n; i++) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0
    out[i] = s & 0xff
  }
  return out
}

// ── zxing-wasm decode-back helper (Node, wasmBinary from node_modules) ────

const require = createRequire(import.meta.url)

beforeAll(() => {
  // Node has no server to serve the .wasm from; inject the binary from
  // node_modules into the zxing module (the browser uses the default path).
  const wasmBuffer = readFileSync(require.resolve('zxing-wasm/full/zxing_full.wasm'))
  const wasmBinary = wasmBuffer.buffer.slice(
    wasmBuffer.byteOffset,
    wasmBuffer.byteOffset + wasmBuffer.byteLength,
  )
  prepareZXingModule({ overrides: { wasmBinary } })
})

async function decodeFrame(
  rgba: Uint8Array,
  canvasSize: number,
  isPure: boolean,
  canvasHeight?: number,
  maxNumberOfSymbols = 4,
): Promise<ReadResult[]> {
  return readBarcodes(
    {
      data: new Uint8ClampedArray(rgba),
      width: canvasSize,
      height: canvasHeight ?? canvasSize,
      // Node has no ImageData global, and zxing-wasm's top-level signature
      // references the DOM ImageData type, which requires colorSpace.
      colorSpace: 'srgb',
    },
    {
      formats: ['QRCode'],
      maxNumberOfSymbols,
      ...(isPure ? { isPure: true } : {}),
    },
  )
}

function expectSingleResult(results: ReadResult[]): ReadResult {
  expect(results).toHaveLength(1)
  const result = results[0]
  if (result === undefined) {
    throw new Error('expected exactly one decoded barcode')
  }
  return result
}

// ── capacity ──────────────────────────────────────────────────────────────

describe('encodeQrBytes capacity', () => {
  it('encodes 1465 bytes at GRID_VERSION 27 (grid capacity)', () => {
    const matrix = encodeQrBytes(pseudoRandomBytes(GRID_CAPACITY), {
      version: GRID_VERSION,
    })
    expect(matrix.size).toBe(125) // v27 → 27*4 + 17
    expect(matrix.modules.length).toBe(125 * 125)
  })

  it('throws DataTooLongError for 1466 bytes at version 27', () => {
    expect(() =>
      encodeQrBytes(pseudoRandomBytes(GRID_CAPACITY + 1), { version: GRID_VERSION }),
    ).toThrow(DataTooLongError)
  })

  it('encodes 2953 bytes at version 40 (MAX_CAPACITY)', () => {
    const matrix = encodeQrBytes(pseudoRandomBytes(MAX_CAPACITY), {
      version: 40,
    })
    expect(matrix.size).toBe(177) // v40 → 40*4 + 17
    expect(matrix.modules.length).toBe(177 * 177)
  })

  it('throws DataTooLongError for 2954 bytes at version 40', () => {
    expect(() => encodeQrBytes(pseudoRandomBytes(MAX_CAPACITY + 1), { version: 40 })).toThrow(
      DataTooLongError,
    )
  })

  it('reports dataLen and version on the DataTooLongError', () => {
    try {
      encodeQrBytes(pseudoRandomBytes(1466), { version: GRID_VERSION })
      expect.unreachable('expected DataTooLongError')
    } catch (err) {
      if (!(err instanceof DataTooLongError)) throw err
      expect(err.dataLen).toBe(1466)
      expect(err.version).toBe(GRID_VERSION)
    }
  })

  it('exports the spec constants', () => {
    expect(MAX_CAPACITY).toBe(2953)
    expect(GRID_VERSION).toBe(27)
    expect(GRID_CAPACITY).toBe(1465)
  })

  it('fitVersion picks the smallest fitting version', () => {
    expect(fitVersion(1465, 'LOW')).toBe(27)
    expect(fitVersion(2953, 'LOW')).toBe(40)
  })

  it('fitVersion throws DataTooLongError beyond version 40', () => {
    expect(() => fitVersion(2954, 'LOW')).toThrow(DataTooLongError)
  })

  it('auto-picks a version when none is given', () => {
    const matrix = encodeQrBytes(pseudoRandomBytes(100))
    expect(matrix.size).toBeGreaterThanOrEqual(21) // v1 → 21 modules
    expect(matrix.size).toBeLessThanOrEqual(125)
  })
})

// ── decode-back: real surface proof via zxing-wasm ────────────────────────

describe('decode-back (encode → render → zxing-wasm)', () => {
  const PPM = 4

  const cases: { name: string; len: number; version?: number }[] = [
    { name: '100 bytes (auto version)', len: 100 },
    { name: '1004 bytes (auto version)', len: 1004 },
    { name: '1465 bytes at V27', len: 1465, version: 27 },
  ]

  it.each(cases)('$name round-trips to the original bytes', async ({ len, version }) => {
    const payload = pseudoRandomBytes(len)
    const matrix = encodeQrBytes(payload, version === undefined ? undefined : { version })
    const canvasSize = (matrix.size + MIN_QUIET_ZONE * 2) * PPM
    const frame = renderSingle(matrix, {
      modules: PPM,
      quietZone: MIN_QUIET_ZONE,
      canvasSize,
    })
    const result = expectSingleResult(await decodeFrame(frame, canvasSize, true))
    expect(result.isValid).toBe(true)
    expect([...result.bytes]).toEqual([...payload])
  })

  it('decodes a V40 tile (2048 bytes) rendered at integerScalePx(177, 800) = 4px/module', async () => {
    const payload = pseudoRandomBytes(2048)
    const matrix = encodeQrBytes(payload, { version: 40 })
    const ppm = integerScalePx(matrix.size, 800)
    expect(ppm).toBe(4) // floor(800 / 177)
    const frame = renderSingle(matrix, { modules: ppm, canvasSize: 800 })
    const result = expectSingleResult(await decodeFrame(frame, 800, true))
    expect(result.isValid).toBe(true)
    expect([...result.bytes]).toEqual([...payload])
  })
})

// ── 2×2 grid ──────────────────────────────────────────────────────────────

describe('renderGrid 2×2 composition', () => {
  it('recovers all 4 payloads from a full 2×2 grid', async () => {
    const payloads = [0x1111, 0x2222, 0x3333, 0x4444].map((seed) =>
      pseudoRandomBytes(GRID_CAPACITY, seed),
    )
    const matrices = payloads.map((p) => encodeQrBytes(p, { version: GRID_VERSION }))
    const canvasSize = 1600
    const frame = renderGrid(matrices, {
      modules: 4,
      quietZone: MIN_QUIET_ZONE,
      canvasSize,
    })
    expect(frame.length).toBe(canvasSize * canvasSize * 4)

    const results = await decodeFrame(frame, canvasSize, false)
    const recovered = new Set<number>()
    for (const result of results) {
      for (let i = 0; i < payloads.length; i++) {
        const payload = payloads[i]
        if (payload === undefined) continue
        if (
          result.bytes.length === payload.length &&
          result.bytes.every((b, j) => b === payload[j])
        ) {
          recovered.add(i)
        }
      }
    }
    expect(recovered).toEqual(new Set([0, 1, 2, 3]))
  })

  it('renders null tiles as solid black quadrants and recovers the real tiles', async () => {
    const a = pseudoRandomBytes(64, 0xaaaa)
    const b = pseudoRandomBytes(64, 0xbbbb)
    const frame = renderGrid(
      [
        encodeQrBytes(a, { version: GRID_VERSION }),
        encodeQrBytes(b, { version: GRID_VERSION }),
        null,
        null,
      ],
      { modules: 4, quietZone: MIN_QUIET_ZONE, canvasSize: 1600 },
    )

    // center of the bottom-left (null) quadrant is opaque black
    const nullQuadrant = (1200 * 1600 + 400) * 4
    expect(frame[nullQuadrant]).toBe(0)
    expect(frame[nullQuadrant + 1]).toBe(0)
    expect(frame[nullQuadrant + 2]).toBe(0)
    expect(frame[nullQuadrant + 3]).toBe(255)

    const results = await decodeFrame(frame, 1600, false)
    const recovered = results.map((r) => [...r.bytes].join(','))
    expect(recovered).toContain([...a].join(','))
    expect(recovered).toContain([...b].join(','))
  })

  it('rejects empty tile lists', () => {
    expect(() => renderGrid([], { modules: 4, canvasSize: 100 })).toThrow(RangeError)
  })

  it('rejects more than 4 tiles', () => {
    const m = () => encodeQrBytes(pseudoRandomBytes(10))
    expect(() => renderGrid([m(), m(), m(), m(), m()], { modules: 4, canvasSize: 100 })).toThrow(
      RangeError,
    )
  })

  it('rejects tiles larger than their quadrant', () => {
    const m = encodeQrBytes(pseudoRandomBytes(GRID_CAPACITY), { version: GRID_VERSION })
    expect(() => renderGrid([m], { modules: 8, canvasSize: 400 })).toThrow(RangeError)
  })
})

// ── quiet zone geometry ───────────────────────────────────────────────────

function countRingViolations(
  frame: Uint8Array,
  canvasSize: number,
  ox: number,
  oy: number,
  tileSide: number,
  ringPx: number,
): number {
  return countRingViolationsRect(frame, canvasSize, canvasSize, ox, oy, tileSide, ringPx)
}

function countRingViolationsRect(
  frame: Uint8Array,
  canvasWidth: number,
  canvasHeight: number,
  ox: number,
  oy: number,
  tileSide: number,
  ringPx: number,
): number {
  let violations = 0
  for (let y = 0; y < canvasHeight; y++) {
    for (let x = 0; x < canvasWidth; x++) {
      const insideTile = x >= ox && x < ox + tileSide && y >= oy && y < oy + tileSide
      const insideRing =
        x >= ox - ringPx &&
        x < ox + tileSide + ringPx &&
        y >= oy - ringPx &&
        y < oy + tileSide + ringPx
      if (insideRing && !insideTile && frame[(y * canvasWidth + x) * 4] !== 255) {
        violations++
      }
    }
  }
  return violations
}

describe('quiet zone', () => {
  it('keeps a full 4-module light ring around a single tile', () => {
    const matrix = encodeQrBytes(pseudoRandomBytes(100))
    const ppm = 4
    const canvasSize = 800
    const frame = renderSingle(matrix, {
      modules: ppm,
      quietZone: MIN_QUIET_ZONE,
      canvasSize,
    })
    const tileSide = (matrix.size + MIN_QUIET_ZONE * 2) * ppm
    const ox = Math.floor((canvasSize - tileSide) / 2)
    expect(countRingViolations(frame, canvasSize, ox, ox, tileSide, MIN_QUIET_ZONE * ppm)).toBe(0)
    // module (0,0) — a dark finder corner — sits one quiet zone in from the tile corner
    const corner = (ox + MIN_QUIET_ZONE * ppm) * canvasSize + (ox + MIN_QUIET_ZONE * ppm)
    expect(frame[corner * 4]).toBe(0)
  })

  it('keeps the quiet zone around every tile in a grid', () => {
    const m = encodeQrBytes(pseudoRandomBytes(GRID_CAPACITY), { version: GRID_VERSION })
    const matrices = [m, m, m, m]
    const ppm = 4
    const canvasSize = 1600
    const frame = renderGrid(matrices, {
      modules: ppm,
      quietZone: MIN_QUIET_ZONE,
      canvasSize,
    })
    const tileSide = (m.size + MIN_QUIET_ZONE * 2) * ppm
    const half = canvasSize / 2
    for (let i = 0; i < 4; i++) {
      const qx = (i % 2) * half
      const qy = Math.floor(i / 2) * half
      const ox = qx + Math.floor((half - tileSide) / 2)
      const oy = qy + Math.floor((half - tileSide) / 2)
      expect(countRingViolations(frame, canvasSize, ox, oy, tileSide, MIN_QUIET_ZONE * ppm)).toBe(0)
    }
  })

  it('renderSingle output is fully opaque RGBA', () => {
    const matrix = encodeQrBytes(pseudoRandomBytes(64))
    const frame = renderSingle(matrix, { modules: 4, canvasSize: 300 })
    expect(frame.length).toBe(300 * 300 * 4)
    let nonOpaque = 0
    for (let i = 3; i < frame.length; i += 4) {
      if (frame[i] !== 255) nonOpaque++
    }
    expect(nonOpaque).toBe(0)
  })
})

// ── integer scaling ───────────────────────────────────────────────────────

describe('integerScalePx', () => {
  it('floors to keep modules crisp', () => {
    expect(integerScalePx(177, 800)).toBe(4) // floor(800/177)
    expect(integerScalePx(177, 885)).toBe(5)
    expect(integerScalePx(125, 300)).toBe(2)
  })

  it('never returns 0 even when the target is smaller than the module count', () => {
    expect(integerScalePx(177, 176)).toBe(1)
  })
})

// ── N×M renderTiles ────────────────────────────────────────────────────────

describe('renderTiles N×M composition', () => {
  const ppm = 4
  const v27 = encodeQrBytes(pseudoRandomBytes(GRID_CAPACITY), { version: GRID_VERSION })
  const v27TileSide = (v27.size + MIN_QUIET_ZONE * 2) * ppm // 532 at ppm 4

  it('recovers all 3 payloads from a 3×1 row on a landscape canvas', async () => {
    const payloads = [0x31, 0x32, 0x33].map((seed) => pseudoRandomBytes(GRID_CAPACITY, seed))
    const matrices = payloads.map((p) => encodeQrBytes(p, { version: GRID_VERSION }))
    const canvasWidth = 1800 // 3 cells of 600
    const canvasHeight = 800 // taller cells: tiles vertically centered in 600×800
    const frame = renderTiles(matrices, {
      modules: ppm,
      cols: 3,
      rows: 1,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth,
      canvasHeight,
    })
    expect(frame.length).toBe(canvasWidth * canvasHeight * 4)

    const results = await decodeFrame(frame, canvasWidth, false, canvasHeight, 3)
    const recovered = results.map((r) => [...r.bytes].join(','))
    for (const p of payloads) {
      expect(recovered).toContain([...p].join(','))
    }
  })

  it('recovers all 3 payloads from a 1×3 column on a portrait canvas', async () => {
    const payloads = [0x41, 0x42, 0x43].map((seed) => pseudoRandomBytes(GRID_CAPACITY, seed))
    const matrices = payloads.map((p) => encodeQrBytes(p, { version: GRID_VERSION }))
    const canvasWidth = 800
    const canvasHeight = 1800 // 3 cells of 600 stacked vertically
    const frame = renderTiles(matrices, {
      modules: ppm,
      cols: 1,
      rows: 3,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth,
      canvasHeight,
    })
    expect(frame.length).toBe(canvasWidth * canvasHeight * 4)

    const results = await decodeFrame(frame, canvasWidth, false, canvasHeight, 3)
    const recovered = results.map((r) => [...r.bytes].join(','))
    for (const p of payloads) {
      expect(recovered).toContain([...p].join(','))
    }
  })

  it('recovers all 9 payloads from a 3×3 grid', async () => {
    const payloads = [0x901, 0x902, 0x903, 0x904, 0x905, 0x906, 0x907, 0x908, 0x909].map((seed) =>
      pseudoRandomBytes(GRID_CAPACITY, seed),
    )
    const matrices = payloads.map((p) => encodeQrBytes(p, { version: GRID_VERSION }))
    const canvasSize = 1800 // 3 cells of 600
    const frame = renderTiles(matrices, {
      modules: ppm,
      cols: 3,
      rows: 3,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth: canvasSize,
    })
    expect(frame.length).toBe(canvasSize * canvasSize * 4)

    const results = await decodeFrame(frame, canvasSize, false, canvasSize, 9)
    const recovered = results.map((r) => [...r.bytes].join(','))
    for (const p of payloads) {
      expect(recovered).toContain([...p].join(','))
    }
  })

  it('recovers a 2048-byte V33 tile at ppm 3', async () => {
    const payload = pseudoRandomBytes(2048)
    const matrix = encodeQrBytes(payload, { version: 33 })
    expect(matrix.size).toBe(149) // 33*4 + 17
    const tilePpm = 3
    const canvasSize = (matrix.size + MIN_QUIET_ZONE * 2) * tilePpm // 471
    const frame = renderTiles([matrix], {
      modules: tilePpm,
      cols: 1,
      rows: 1,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth: canvasSize,
    })
    const result = expectSingleResult(await decodeFrame(frame, canvasSize, true))
    expect(result.isValid).toBe(true)
    expect([...result.bytes]).toEqual([...payload])
  })

  it('recovers a 2560-byte V40 tile at ppm 3', async () => {
    const payload = pseudoRandomBytes(2560)
    const matrix = encodeQrBytes(payload, { version: 40 })
    expect(matrix.size).toBe(177) // 40*4 + 17
    const tilePpm = 3
    const canvasSize = (matrix.size + MIN_QUIET_ZONE * 2) * tilePpm // 555
    const frame = renderTiles([matrix], {
      modules: tilePpm,
      cols: 1,
      rows: 1,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth: canvasSize,
    })
    const result = expectSingleResult(await decodeFrame(frame, canvasSize, true))
    expect(result.isValid).toBe(true)
    expect([...result.bytes]).toEqual([...payload])
  })

  it('fills null cells black and still recovers the real tiles', async () => {
    const a = pseudoRandomBytes(64, 0xa11)
    const b = pseudoRandomBytes(64, 0xb22)
    const frame = renderTiles(
      [
        encodeQrBytes(a, { version: GRID_VERSION }),
        null,
        encodeQrBytes(b, { version: GRID_VERSION }),
      ],
      {
        modules: ppm,
        cols: 3,
        rows: 1,
        quietZone: MIN_QUIET_ZONE,
        canvasWidth: 1800,
        canvasHeight: 800,
      },
    )

    // center of the middle (null) cell — x in [600, 1200), y in [0, 800)
    const nullCenter = (400 * 1800 + 900) * 4
    expect(frame[nullCenter]).toBe(0)
    expect(frame[nullCenter + 1]).toBe(0)
    expect(frame[nullCenter + 2]).toBe(0)
    expect(frame[nullCenter + 3]).toBe(255)

    const results = await decodeFrame(frame, 1800, false, 800, 3)
    const recovered = results.map((r) => [...r.bytes].join(','))
    expect(recovered).toContain([...a].join(','))
    expect(recovered).toContain([...b].join(','))
  })

  it('keeps the quiet zone around every tile in a 3×3 grid', () => {
    const frame = renderTiles(Array(9).fill(v27), {
      modules: ppm,
      cols: 3,
      rows: 3,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth: 1800,
    })
    const cell = 600
    for (let i = 0; i < 9; i++) {
      const ox = (i % 3) * cell + Math.floor((cell - v27TileSide) / 2)
      const oy = Math.floor(i / 3) * cell + Math.floor((cell - v27TileSide) / 2)
      expect(
        countRingViolationsRect(frame, 1800, 1800, ox, oy, v27TileSide, MIN_QUIET_ZONE * ppm),
      ).toBe(0)
    }
  })

  it('keeps the quiet zone around every tile in a 3×1 row on a landscape canvas', () => {
    const frame = renderTiles([v27, v27, v27], {
      modules: ppm,
      cols: 3,
      rows: 1,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth: 1800,
      canvasHeight: 800,
    })
    const cellW = 600
    const cellH = 800
    for (let i = 0; i < 3; i++) {
      const ox = i * cellW + Math.floor((cellW - v27TileSide) / 2)
      const oy = Math.floor((cellH - v27TileSide) / 2)
      expect(
        countRingViolationsRect(frame, 1800, 800, ox, oy, v27TileSide, MIN_QUIET_ZONE * ppm),
      ).toBe(0)
    }
  })

  it('rejects empty tile lists', () => {
    expect(() => renderTiles([], { modules: ppm, cols: 2, rows: 2, canvasWidth: 100 })).toThrow(
      RangeError,
    )
  })

  it('rejects more tiles than cells', () => {
    const m = () => encodeQrBytes(pseudoRandomBytes(10))
    expect(() =>
      renderTiles([m(), m(), m(), m(), m()], {
        modules: ppm,
        cols: 2,
        rows: 2,
        canvasWidth: 100,
      }),
    ).toThrow(RangeError)
  })

  it('rejects tiles larger than their cell', () => {
    expect(() => renderTiles([v27], { modules: 8, cols: 1, rows: 1, canvasWidth: 400 })).toThrow(
      RangeError,
    )
  })

  it('renders a portrait canvas at canvasWidth × canvasHeight × 4', () => {
    const m = encodeQrBytes(pseudoRandomBytes(64))
    const frame = renderTiles([m], {
      modules: ppm,
      cols: 1,
      rows: 1,
      quietZone: MIN_QUIET_ZONE,
      canvasWidth: 900,
      canvasHeight: 2400,
    })
    expect(frame.length).toBe(900 * 2400 * 4) // 8,640,000
  })

  it('renderGrid (4 tiles) is byte-identical to renderTiles with cols 2 rows 2', () => {
    const payloads = [0x71, 0x72, 0x73, 0x74].map((seed) => pseudoRandomBytes(GRID_CAPACITY, seed))
    const matrices = payloads.map((p) => encodeQrBytes(p, { version: GRID_VERSION }))
    const canvasSize = 1600
    const grid = renderGrid(matrices, { modules: ppm, quietZone: MIN_QUIET_ZONE, canvasSize })
    const tiles = renderTiles(matrices, {
      modules: ppm,
      quietZone: MIN_QUIET_ZONE,
      cols: 2,
      rows: 2,
      canvasWidth: canvasSize,
    })
    expect(grid.length).toBe(tiles.length)
    expect(grid.every((v, i) => v === tiles[i])).toBe(true)
  })

  it('renderSingle is byte-identical to renderTiles with cols 1 rows 1', () => {
    const canvasSize = 1600
    const single = renderSingle(v27, { modules: ppm, quietZone: MIN_QUIET_ZONE, canvasSize })
    const tiles = renderTiles([v27], {
      modules: ppm,
      quietZone: MIN_QUIET_ZONE,
      cols: 1,
      rows: 1,
      canvasWidth: canvasSize,
    })
    expect(single.length).toBe(tiles.length)
    expect(single.every((v, i) => v === tiles[i])).toBe(true)
  })
})

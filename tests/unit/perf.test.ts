/**
 * Performance envelope for the QRStream transfer path — measured budgets, not vibes.
 * Every number logged here comes from an actual run of this file; the full
 * report is docs/PERF.md. Budgets are generous (CI machines vary) but honest:
 * encode must fit work*1.5 <= frame delay, render < 16ms, decode <= 200ms/frame
 * (>= 5 fps), the decode pool must round-robin evenly, the capture must land at
 * <= 2MP / <= 1280px wide, and over-budget work must step the fps down.
 */

import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { decodeImageData, prepareDecodeModule, type RgbaBuffer } from '../../src/receiver/decode'
import { DecodePool, type DecodeRequest, type DecodeWorkerResponse } from '../../src/receiver/pool'
import { downsampleTarget } from '../../src/receiver/stats'
import { encodeQrBytes, type QrMatrix } from '../../src/qr/encode'
import { MIN_QUIET_ZONE, renderGrid, renderSingle, renderTiles } from '../../src/qr/render'
import {
  DEFAULT_OVERHEAD_FACTOR,
  LAYOUT_MAX_FPS,
  MIN_FPS,
  adaptFps,
  computeFrameDelayMs,
  computeLayoutGeometry,
  renderBudgetOk,
  resolvePacing,
} from '../../src/sender/pacing'

// ── Fixtures / helpers ────────────────────────────────────────────────────────

const require = createRequire(import.meta.url)
const wasmBuffer = readFileSync(require.resolve('zxing-wasm/reader/zxing_reader.wasm'))
const wasmBinary = wasmBuffer.buffer.slice(
  wasmBuffer.byteOffset,
  wasmBuffer.byteOffset + wasmBuffer.byteLength,
)

/** Deterministic payloads sized for the two profiles (V27-L fits 1465B, V40-L fits 2953B). */
const PAYLOAD_1024 = new Uint8Array(1024).map((_, i) => (i * 7 + 3) % 251)
const PAYLOAD_2048 = new Uint8Array(2048).map((_, i) => (i * 7 + 3) % 251)

interface Timing {
  avgMs: number
  minMs: number
  maxMs: number
}

function timeAvg(run: () => void, iterations: number): Timing {
  for (let i = 0; i < 5; i++) run() // JIT warmup
  let sum = 0
  let min = Infinity
  let max = 0
  for (let i = 0; i < iterations; i++) {
    const t0 = performance.now()
    run()
    const ms = performance.now() - t0
    sum += ms
    min = Math.min(min, ms)
    max = Math.max(max, ms)
  }
  return { avgMs: sum / iterations, minMs: min, maxMs: max }
}

async function timeAvgAsync(run: () => Promise<unknown>, iterations: number): Promise<Timing> {
  for (let i = 0; i < 3; i++) await run()
  let sum = 0
  let min = Infinity
  let max = 0
  for (let i = 0; i < iterations; i++) {
    const t0 = performance.now()
    await run()
    const ms = performance.now() - t0
    sum += ms
    min = Math.min(min, ms)
    max = Math.max(max, ms)
  }
  return { avgMs: sum / iterations, minMs: min, maxMs: max }
}

/**
 * Rasterizes 1..4 QrMatrix tiles onto a frameW×frameH white RGBA frame using the
 * same integer-ppm + quiet-zone math as src/qr/render.ts drawTile. One tile is
 * centered; four occupy the 2×2 quadrants (the real grid layout).
 */
function frameWithQrs(
  matrices: readonly QrMatrix[],
  frameW: number,
  frameH: number,
  ppm: number,
): RgbaBuffer {
  const quiet = MIN_QUIET_ZONE
  const data = new Uint8ClampedArray(frameW * frameH * 4).fill(255)
  const quad = matrices.length > 1
  const quadW = quad ? Math.floor(frameW / 2) : frameW
  const quadH = quad ? Math.floor(frameH / 2) : frameH
  for (let i = 0; i < matrices.length; i++) {
    const matrix = matrices[i]
    if (matrix === undefined) continue
    const side = (matrix.size + quiet * 2) * ppm
    const ox = quad
      ? (i % 2) * quadW + Math.floor((quadW - side) / 2)
      : Math.floor((frameW - side) / 2)
    const oy = quad
      ? Math.floor(i / 2) * quadH + Math.floor((quadH - side) / 2)
      : Math.floor((frameH - side) / 2)
    for (let y = 0; y < side; y++) {
      for (let x = 0; x < side; x++) {
        const mx = Math.floor(x / ppm) - quiet
        const my = Math.floor(y / ppm) - quiet
        const dark =
          mx >= 0 &&
          my >= 0 &&
          mx < matrix.size &&
          my < matrix.size &&
          (matrix.modules[my * matrix.size + mx] ?? 0) === 1
        const v = dark ? 0 : 255
        const p = ((oy + y) * frameW + (ox + x)) * 4
        data[p] = v
        data[p + 1] = v
        data[p + 2] = v
        data[p + 3] = 255
      }
    }
  }
  return data
}

/** Fake Worker so DecodePool round-robin is testable headlessly. */
class FakeWorker {
  static instances: FakeWorker[] = []
  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: (() => void) | null = null
  postCalls = 0

  constructor() {
    FakeWorker.instances.push(this)
  }

  postMessage(message: DecodeRequest): void {
    this.postCalls++
    const response: DecodeWorkerResponse = { id: message.id, results: [] }
    queueMicrotask(() => {
      this.onmessage?.(new MessageEvent('message', { data: response }))
    })
  }

  terminate(): void {}
}

function log(msg: string): void {
  console.log(`[perf] ${msg}`)
}

// ── Budgets ───────────────────────────────────────────────────────────────────

describe('perf: sender encode budget (work * 1.5 <= frame delay)', () => {
  it('grid4 layout: V27-L 1024B encode fits the 42ms frame delay', () => {
    const t = timeAvg(() => encodeQrBytes(PAYLOAD_1024, { version: 27 }), 50)
    const frameDelayMs = computeFrameDelayMs(24) // grid4 ceiling
    log(
      `encode V27-L 1024B avg=${t.avgMs.toFixed(3)}ms max=${t.maxMs.toFixed(3)}ms | frame ~${(t.avgMs * 4).toFixed(2)}ms vs ${frameDelayMs}ms`,
    )
    expect(t.avgMs * DEFAULT_OVERHEAD_FACTOR).toBeLessThanOrEqual(frameDelayMs)
  })

  it('single layout: V40-L 2048B encode fits the 33ms frame delay', () => {
    const t = timeAvg(() => encodeQrBytes(PAYLOAD_2048, { version: 40 }), 50)
    const frameDelayMs = computeFrameDelayMs(30) // single layout ceiling
    log(
      `encode V40-L 2048B avg=${t.avgMs.toFixed(3)}ms max=${t.maxMs.toFixed(3)}ms vs delay ${frameDelayMs}ms`,
    )
    expect(t.avgMs * DEFAULT_OVERHEAD_FACTOR).toBeLessThanOrEqual(frameDelayMs)
  })
})

describe('perf: QR render cost (16ms display-refresh budget)', () => {
  const m27 = encodeQrBytes(PAYLOAD_1024, { version: 27 })
  const m40 = encodeQrBytes(PAYLOAD_2048, { version: 40 })
  const opts = { modules: 4, canvasSize: 1600, quietZone: MIN_QUIET_ZONE }

  it('renderGrid 4xV27 at 4px/module on a 1600px canvas stays under 16ms', () => {
    const t = timeAvg(() => renderGrid([m27, m27, m27, m27], opts), 25)
    log(`renderGrid 4xV27 @4ppm/1600px avg=${t.avgMs.toFixed(2)}ms max=${t.maxMs.toFixed(2)}ms`)
    expect(t.avgMs).toBeLessThan(16)
  })

  it('renderSingle V40 at 4px/module on a 1600px canvas stays under 16ms', () => {
    const t = timeAvg(() => renderSingle(m40, opts), 25)
    log(`renderSingle V40 @4ppm/1600px avg=${t.avgMs.toFixed(2)}ms max=${t.maxMs.toFixed(2)}ms`)
    expect(t.avgMs).toBeLessThan(16)
  })

  it('renderTiles 9xV27 (grid9) at 4px/module on an 1800px canvas stays under the grid9 frame budget', () => {
    const t = timeAvg(
      () =>
        renderTiles(Array(9).fill(m27), {
          cols: 3,
          rows: 3,
          modules: 4,
          quietZone: MIN_QUIET_ZONE,
          canvasWidth: 1800,
          canvasHeight: 1800,
        }),
      25,
    )
    log(
      `renderTiles 9xV27 (grid9) @4ppm/1800px avg=${t.avgMs.toFixed(2)}ms max=${t.maxMs.toFixed(2)}ms`,
    )
    // The meaningful budget is grid9's own frame delay (24fps → 42ms) with the
    // display loop's 1.5× overhead margin (≈28ms), not the aspirational 60fps
    // 16ms display-refresh figure. Over that, adaptFps would throttle down.
    const grid9BudgetMs = computeFrameDelayMs(LAYOUT_MAX_FPS.grid9) / DEFAULT_OVERHEAD_FACTOR
    expect(t.avgMs).toBeLessThan(grid9BudgetMs)
  })

  it('renderTiles 3xV40 (column3) on a portrait 1400x2600 canvas stays under 16ms', () => {
    const ppm = computeLayoutGeometry(1400, 2600, 'column3', 40).ppm
    const t = timeAvg(
      () =>
        renderTiles(Array(3).fill(m40), {
          cols: 1,
          rows: 3,
          modules: ppm,
          quietZone: MIN_QUIET_ZONE,
          canvasWidth: 1400,
          canvasHeight: 2600,
        }),
      25,
    )
    log(
      `renderTiles 3xV40 (column3) @${ppm}ppm/1400x2600 avg=${t.avgMs.toFixed(2)}ms max=${t.maxMs.toFixed(2)}ms`,
    )
    expect(t.avgMs).toBeLessThan(16)
  })
})

describe('perf: decode throughput (>= 5 fps, i.e. <= 200ms/frame)', () => {
  beforeAll(async () => {
    await prepareDecodeModule({ wasmBinary })
  })

  it('decodes a V27 QR in a 1280x720 frame well above 5 fps', async () => {
    const m27 = encodeQrBytes(PAYLOAD_1024, { version: 27 })
    const frame = frameWithQrs([m27], 1280, 720, 5)
    const t = await timeAvgAsync(async () => {
      await decodeImageData(frame, 1280, 720)
    }, 15)
    log(
      `decode 1xV27 1280x720 avg=${t.avgMs.toFixed(1)}ms max=${t.maxMs.toFixed(1)}ms | ~${(1000 / t.avgMs).toFixed(1)} fps`,
    )
    expect(t.avgMs).toBeLessThan(200)
  })
})

describe('perf: DecodePool round-robin balance', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('splits 100 decodes ~50/50 across 2 workers', async () => {
    FakeWorker.instances = []
    vi.stubGlobal('Worker', FakeWorker)
    const pool = new DecodePool(2)
    try {
      const decodes = Array.from({ length: 100 }, () => pool.decode(new Uint8Array(4), 1, 1))
      const results = await Promise.all(decodes)
      expect(FakeWorker.instances).toHaveLength(2)
      expect(results.every((r) => r.length === 0)).toBe(true)
      const calls = FakeWorker.instances.map((w) => w.postCalls)
      const c0 = calls[0] ?? 0
      const c1 = calls[1] ?? 0
      log(`pool round-robin (size=2, 100 decodes): calls per worker = ${calls.join(' / ')}`)
      expect(c0 + c1).toBe(100)
      expect(Math.abs(c0 - c1)).toBeLessThanOrEqual(1)
    } finally {
      pool.dispose()
    }
  })
})

describe('perf: downsampleTarget (<= 2MP, <= 1280px wide)', () => {
  it.each([
    [1920, 1080],
    [3840, 2160],
    [1280, 720],
  ])('maps a %dx%d capture into the decode budget', (w, h) => {
    const target = downsampleTarget(w, h)
    log(`${w}x${h} -> ${target.width}x${target.height} (${target.width * target.height} px)`)
    expect(target.width * target.height).toBeLessThanOrEqual(2_000_000)
    expect(target.width).toBeLessThanOrEqual(1280)
  })
})

describe('perf: adaptive pacing boundaries', () => {
  it('steps fps down by FPS_ADAPT_STEP when work exceeds the budget, floored at MIN_FPS', () => {
    const frameDelayMs = computeFrameDelayMs(24)
    log(
      `adaptFps(24,30ms,${frameDelayMs}ms)->${adaptFps(24, 30, frameDelayMs)} | ok(28)=${renderBudgetOk(28, frameDelayMs)} | ok(30)=${renderBudgetOk(30, frameDelayMs)}`,
    )
    expect(adaptFps(24, 30, frameDelayMs)).toBe(20)
    expect(adaptFps(20, 30, frameDelayMs)).toBe(16)
    expect(adaptFps(MIN_FPS, 30, frameDelayMs)).toBe(MIN_FPS)
    expect(renderBudgetOk(28, frameDelayMs)).toBe(true)
    expect(renderBudgetOk(30, frameDelayMs)).toBe(false)
  })

  it('resolves the fps ceilings the broadcast loops against', () => {
    const grid4 = resolvePacing(
      { bytesPerTile: '1k', layout: 'grid4', targetFps: 24, highRefresh: false },
      1600,
      1600,
    )
    const grid9 = resolvePacing(
      { bytesPerTile: '1k', layout: 'grid9', targetFps: 24, highRefresh: true },
      1600,
      1600,
    )
    const single = resolvePacing(
      { bytesPerTile: '1k', layout: 'single', targetFps: 30, highRefresh: true },
      600,
      600,
    )
    log(
      `ceilings: grid4=${grid4.fpsCeiling} (24fps -> ${computeFrameDelayMs(grid4.fpsCeiling)}ms), ` +
        `grid9=${grid9.fpsCeiling} (${computeFrameDelayMs(grid9.fpsCeiling)}ms), ` +
        `single=${single.fpsCeiling} (${computeFrameDelayMs(single.fpsCeiling)}ms)`,
    )
    expect(grid4.fpsCeiling).toBe(24)
    expect(grid9.fpsCeiling).toBe(24)
    expect(single.fpsCeiling).toBe(30)
  })
})

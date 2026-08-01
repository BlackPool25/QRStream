import { expect, test } from '@playwright/test'

/**
 * Real-browser perf envelope for the sender broadcast path.
 *
 * Measures the ACTUAL broadcast loop on a 1600x1600 viewport (grid profile:
 * canvasSize >= GRID_MIN_CANVAS_PX) and an 800x800 viewport (single-V40
 * profile): sustained tick rate over an ~6-8s window, derived average tick
 * time, the final stats chips (profile / k / dropped), and the px/module
 * geometry the camera would see. Assertions are deliberately loose — CI
 * machines vary — and the measured numbers are logged for docs/PERF.md. The
 * receiver decode rate is measured at the unit level (tests/unit/perf.test.ts)
 * since the virtual-camera transfer e2e (T18) has not landed.
 */

const GRID_MIN_CANVAS_PX = 1600

/** Deterministic PRNG (mulberry32) — incompressible payload exercises the real path. */
function mulberry32(seed: number): () => number {
  let state = seed
  return () => {
    state |= 0
    state = (state + 0x6d2b79f5) | 0
    let t = Math.imul(state ^ (state >>> 15), 1 | state)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function randomBytes(size: number, seed: number): Buffer {
  const rand = mulberry32(seed)
  const bytes = Buffer.alloc(size)
  for (let i = 0; i < size; i++) bytes[i] = Math.floor(rand() * 256)
  return bytes
}

interface BroadcastSample {
  samples: number[]
  state: { chips: string; canvasSize: number; ppm: number }
}

/** Drives the UI into a live broadcast and samples the fps chip for windowMs. */
async function sampleBroadcast(
  page: import('@playwright/test').Page,
  viewport: { width: number; height: number },
  windowMs: number,
): Promise<BroadcastSample> {
  await page.setViewportSize(viewport)
  await page.goto('/')
  await page.getByRole('button', { name: 'Send a file' }).click()
  await page.setInputFiles('input[type="file"]', {
    name: 'perf-64k.bin',
    mimeType: 'application/octet-stream',
    buffer: randomBytes(64 * 1024, 0x51a1e),
  })
  await page.getByRole('button', { name: 'Begin broadcast' }).click()
  await expect(page.locator('.stats-chips').getByText(/fps/)).toBeVisible()

  const samples = await page.evaluate(async (ms: number) => {
    const chipText = () =>
      Array.from(document.querySelectorAll('.chip'))
        .map((chip) => chip.textContent ?? '')
        .join(' ')
    const out: number[] = []
    const deadline = performance.now() + ms
    while (performance.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 500))
      const match = /([\d.]+)\s*fps/.exec(chipText())
      const fps = match?.[1] === undefined ? undefined : Number(match[1])
      if (fps !== undefined) out.push(fps)
    }
    return out
  }, windowMs)

  const state = await page.evaluate(() => {
    const chips = () =>
      Array.from(document.querySelectorAll('.chip'))
        .map((chip) => chip.textContent ?? '')
        .join(' | ')
    const canvas = document.querySelector('canvas.qr-canvas')
    const side = canvas instanceof HTMLCanvasElement ? Math.min(canvas.width, canvas.height) : 0
    // The app always broadcasts the grid profile (chooseProfile is not wired
    // into the broadcast path), so px/module comes from the grid tile area.
    const modules = 27 * 4 + 17 + 2 * 4
    return { chips: chips(), canvasSize: side, ppm: Math.floor(side / 2 / modules) }
  })
  return { samples, state }
}

test('grid profile sustains its fps budget on a 1600px canvas', async ({ page }) => {
  const { samples, state } = await sampleBroadcast(page, { width: 1600, height: 1600 }, 8000)
  const avgFps = samples.reduce((a, b) => a + b, 0) / Math.max(1, samples.length)
  const avgTickMs = samples.reduce((a, b) => a + 1000 / b, 0) / Math.max(1, samples.length)
  console.log(
    `[perf-e2e] grid: samples=${samples.length} avgFps=${avgFps.toFixed(1)} minFps=${Math.min(...samples).toFixed(1)} ` +
      `avgTickMs=${avgTickMs.toFixed(1)}`,
  )
  console.log(`[perf-e2e] grid: chips: ${state.chips}`)
  console.log(
    `[perf-e2e] grid: canvas ${state.canvasSize}x${state.canvasSize}px -> ~${state.ppm} px/module`,
  )
  expect(samples.length).toBeGreaterThanOrEqual(4)
  expect(state.canvasSize).toBeGreaterThanOrEqual(GRID_MIN_CANVAS_PX)
  expect(state.ppm).toBeGreaterThanOrEqual(4)
  // MIN_FPS is the design floor the adaptive loop protects; unloaded runs hit
  // ~12fps (60Hz quantization of the 15fps target), ~10.7fps under parallel
  // load — 8 keeps CI honest on slower/loaded runners.
  expect(avgFps).toBeGreaterThanOrEqual(8)
})

test('compact-canvas grid broadcast (800px, ~3px/module tiles) sustains its fps budget', async ({
  page,
}) => {
  const { samples, state } = await sampleBroadcast(page, { width: 800, height: 800 }, 6000)
  const avgFps = samples.reduce((a, b) => a + b, 0) / Math.max(1, samples.length)
  const avgTickMs = samples.reduce((a, b) => a + 1000 / b, 0) / Math.max(1, samples.length)
  console.log(
    `[perf-e2e] small: samples=${samples.length} avgFps=${avgFps.toFixed(1)} minFps=${Math.min(...samples).toFixed(1)} ` +
      `avgTickMs=${avgTickMs.toFixed(1)}`,
  )
  console.log(`[perf-e2e] small: chips: ${state.chips}`)
  console.log(
    `[perf-e2e] small: canvas ${state.canvasSize}x${state.canvasSize}px -> ~${state.ppm} px/module`,
  )
  expect(samples.length).toBeGreaterThanOrEqual(4)
  expect(state.canvasSize).toBeLessThan(GRID_MIN_CANVAS_PX)
  expect(state.ppm).toBeGreaterThanOrEqual(2)
  expect(avgFps).toBeGreaterThanOrEqual(8)
})

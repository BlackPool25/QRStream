#!/usr/bin/env node
// Captures a REAL animated GIF of the QR grid cycling — the sender canvas at a
// small size (QRs are high-contrast black/white, so ~10fps for 6s stays tiny),
// frames stitched with ffmpeg palettegen.
// Usage: node scripts/make-qr-gif.mjs   (needs `npm run build` + ffmpeg)

import { chromium } from 'playwright'
import { spawn } from 'node:child_process'
import { execSync } from 'node:child_process'
import { mkdirSync, rmSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..')
const OUT = path.join(ROOT, 'docs', 'screenshots')
const FRAMES = path.join('/tmp', 'qrstream-frames')
const BASE = 'http://127.0.0.1:4173'
const VIEW = { width: 420, height: 420 } // tight 2×2 grid crop
const FPS = 10
const DURATION_S = 6
const FRAME_COUNT = FPS * DURATION_S

mkdirSync(OUT, { recursive: true })
rmSync(FRAMES, { recursive: true, force: true })
mkdirSync(FRAMES, { recursive: true })

function mulberry32(seed) {
  let a = seed >>> 0
  return () => {
    a += 0x6d2b79f5
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}
function buildRandomBytes(size, seed) {
  const rand = mulberry32(seed)
  const bytes = Buffer.alloc(size)
  for (let i = 0; i < size; i++) bytes[i] = Math.floor(rand() * 256)
  return bytes
}

async function waitForCanvas(page, timeout = 30000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const nonBlank = await page.evaluate(() => {
      const c = document.querySelector('canvas.qr-canvas')
      if (!c) return false
      const ctx = c.getContext('2d')
      if (!ctx) return false
      const w = Math.min(c.width, 64)
      const h = Math.min(c.height, 64)
      const d = ctx.getImageData(0, 0, w, h).data
      let sum = 0
      for (let i = 0; i < d.length; i += 4) sum += d[i]
      return sum > 0
    })
    if (nonBlank) return
    await page.waitForTimeout(200)
  }
  throw new Error('canvas never rendered')
}

let server
function startServer() {
  return new Promise((resolve) => {
    server = spawn(
      'npm',
      ['run', 'preview', '--', '--port', '4173', '--strictPort', '--host', '127.0.0.1'],
      {
        cwd: ROOT,
        stdio: 'ignore',
      },
    )
    const poll = async () => {
      try {
        const r = await fetch(BASE)
        if (r.ok) return resolve()
      } catch {
        /* not up yet */
      }
      setTimeout(poll, 300)
    }
    poll()
  })
}

try {
  await startServer()
  const browser = await chromium.launch()
  const page = await browser.newPage({ viewport: VIEW })
  await page.goto(BASE)
  await page.getByRole('button', { name: 'Send a file' }).click()
  await page.locator('input[type="file"]').setInputFiles({
    name: 'demo.bin',
    mimeType: 'application/octet-stream',
    buffer: buildRandomBytes(64 * 1024, 11),
  })
  await page.getByRole('button', { name: 'Begin broadcast' }).waitFor({ timeout: 30000 })
  await page.getByRole('button', { name: 'Begin broadcast' }).click()
  await waitForCanvas(page)

  // Let the first QR frame settle, then capture a cycling sequence.
  await page.waitForTimeout(600)
  for (let i = 0; i < FRAME_COUNT; i++) {
    await page
      .locator('canvas.qr-canvas')
      .screenshot({ path: `${FRAMES}/f${String(i).padStart(3, '0')}.png` })
    await page.waitForTimeout(1000 / FPS)
  }

  await browser.close()
  execSync(
    `ffmpeg -y -framerate ${FPS} -i ${FRAMES}/f%03d.png -vf "fps=${FPS},scale=420:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" -loop 0 ${OUT}/qr-cycling.gif`,
    { stdio: 'ignore' },
  )
  console.log('wrote', OUT + '/qr-cycling.gif')
} finally {
  if (server) server.kill()
  rmSync(FRAMES, { recursive: true, force: true })
}

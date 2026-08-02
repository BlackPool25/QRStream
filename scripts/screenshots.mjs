#!/usr/bin/env node
/**
 * README marketing captures for the QRStream OSS launch.
 *
 * Reuses the battle-tested virtual-camera flow from tests/e2e/helpers
 * (startSenderBroadcast / openReceiverWithVirtualCamera / waitForSymbolsReceived /
 * waitForVerifiedBadge) but drives it through the plain `playwright` library,
 * outside the @playwright/test runner. Produces, under docs/screenshots/:
 *   hero-broadcast.png        2x2 grid4 broadcast stage (1440x1440 @ dsf 2)
 *   phone-send.png            column3 broadcast on a 390x844 portrait phone
 *   receive-transferring.png  receiver mid-transfer with live stats overlay
 *   receive-verified.png      receiver with the ✓ VERIFIED (SHA-256) badge
 *   send-settings.png         the sender settings panel (bonus)
 * and records a receiver-page webm in /tmp for the transfer-demo.gif pass.
 *
 * The preview server is spawned (or reused if already up) and killed on exit.
 */

import { chromium } from 'playwright'
import { mkdirSync, rmSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..')
const OUT = path.join(ROOT, 'docs', 'screenshots')
const TMP = '/tmp/qrstream-shots'
const BASE = 'http://127.0.0.1:4173'
const RANDOM_MIME = 'application/octet-stream'

mkdirSync(OUT, { recursive: true })
rmSync(TMP, { recursive: true, force: true })
mkdirSync(TMP, { recursive: true })

// ---- deterministic fixtures (mirror of tests/e2e/helpers/fixtures.ts) ----
function mulberry32(seed) {
  let state = seed
  return () => {
    state |= 0
    state = (state + 0x6d2b79f5) | 0
    let t = Math.imul(state ^ (state >>> 15), 1 | state)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function buildRandomBytes(size, seed) {
  const rand = mulberry32(seed)
  const bytes = Buffer.alloc(size)
  for (let i = 0; i < size; i++) bytes[i] = Math.floor(rand() * 256)
  return bytes
}

// ---- preview server ----
let server = null
async function ensureServer() {
  try {
    const res = await fetch(`${BASE}/`)
    if (res.ok) {
      console.log('[server] reuse existing preview on', BASE)
      return
    }
  } catch {
    /* not up — spawn */
  }
  server = spawn(
    'npm',
    ['run', 'preview', '--', '--port', '4173', '--strictPort', '--host', '127.0.0.1'],
    { cwd: ROOT, stdio: 'ignore', detached: false },
  )
  const deadline = Date.now() + 60_000
  for (;;) {
    try {
      const res = await fetch(`${BASE}/`)
      if (res.ok) {
        console.log('[server] spawned preview on', BASE)
        return
      }
    } catch {
      /* keep polling */
    }
    if (Date.now() > deadline) throw new Error('preview server did not come up in 60s')
    await new Promise((r) => setTimeout(r, 300))
  }
}

function stopServer() {
  if (server !== null) {
    try {
      server.kill('SIGTERM')
    } catch {
      /* already dead */
    }
    server = null
  }
}

// ---- sender flow (mirror of startSenderBroadcast) ----
async function waitForSelector(page, selector, timeout, msg) {
  const deadline = Date.now() + timeout
  for (;;) {
    if (
      await page
        .locator(selector)
        .first()
        .isVisible()
        .catch(() => false)
    )
      return
    if (Date.now() > deadline) throw new Error(msg ?? `timeout waiting for ${selector}`)
    await page.waitForTimeout(150)
  }
}

async function waitForButton(page, name, timeout, msg) {
  const deadline = Date.now() + timeout
  for (;;) {
    if (
      await page
        .getByRole('button', { name })
        .first()
        .isVisible()
        .catch(() => false)
    )
      return
    if (Date.now() > deadline) throw new Error(msg ?? `timeout waiting for button "${name}"`)
    await page.waitForTimeout(150)
  }
}

async function waitForCanvas(page, timeout = 30_000) {
  const deadline = Date.now() + timeout
  for (;;) {
    const sum = await page
      .evaluate(() => {
        const canvas = document.querySelector('canvas.qr-canvas')
        if (!(canvas instanceof HTMLCanvasElement) || canvas.width === 0) return 0
        const ctx = canvas.getContext('2d')
        if (ctx === null) return 0
        const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height).data
        let sum = 0
        for (let i = 0; i < pixels.length; i += 16) sum += pixels[i] ?? 0
        return sum
      })
      .catch(() => 0)
    if (sum > 0) return
    if (Date.now() > deadline) throw new Error('broadcast canvas never rendered')
    await page.waitForTimeout(200)
  }
}

async function waitForChips(page, timeout = 15_000) {
  const deadline = Date.now() + timeout
  for (;;) {
    const has = await page
      .evaluate(() => {
        const chips = [...document.querySelectorAll('.stats-chips .chip')]
        return chips.some((c) => /\d+(\.\d+)?\s*fps/.test(c.textContent ?? ''))
      })
      .catch(() => false)
    if (has) return
    if (Date.now() > deadline) throw new Error('sender stats chips never populated')
    await page.waitForTimeout(200)
  }
}

async function startSender(context, viewport, fixture, { layout } = {}) {
  const page = await context.newPage()
  await page.setViewportSize(viewport)
  await page.goto(BASE)
  await page.getByRole('button', { name: 'Send a file' }).click()
  await page.locator('input[type="file"]').setInputFiles({
    name: fixture.name,
    mimeType: fixture.mime,
    buffer: fixture.bytes,
  })
  await waitForButton(page, 'Begin broadcast', 20_000, 'settings panel never appeared')
  if (layout !== undefined) {
    await page
      .getByRole('radiogroup', { name: 'Tile layout' })
      .locator(`[data-layout="${layout}"]`)
      .click()
  }
  await page.getByRole('button', { name: 'Begin broadcast' }).click()
  await waitForCanvas(page)
  await page.evaluate(() => {
    const canvas = document.querySelector('canvas.qr-canvas')
    if (!(canvas instanceof HTMLCanvasElement)) throw new Error('broadcast canvas not found')
    window.__senderStream = canvas.captureStream(30)
  })
  return page
}

// ---- receiver flow (mirror of openReceiverWithVirtualCamera) ----
async function openReceiver(context, sender) {
  const [receiver] = await Promise.all([
    context.waitForEvent('page'),
    sender.evaluate(() => {
      const opened = window.open('/', '_blank')
      if (opened === null) throw new Error('window.open was blocked')
    }),
  ])
  await receiver.waitForLoadState('domcontentloaded')
  await receiver.evaluate(() => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: async () => {
          const stream = window.opener?.__senderStream
          if (stream === undefined) throw new Error('sender broadcast stream not ready')
          return stream
        },
        getSupportedConstraints: () => ({ frameRate: true }),
        enumerateDevices: async () => [],
      },
    })
  })
  return receiver
}

async function startScanning(receiver) {
  await receiver.getByRole('button', { name: 'Receive a file' }).click()
  await receiver.getByRole('button', { name: 'Start scanning' }).click()
}

async function readCount(page) {
  return page
    .evaluate(() => {
      const el = document.querySelector('.so-count')
      if (el === null) return null
      const m = /^\s*(\d+)\s*\/\s*(\d+)/.exec(el.textContent ?? '')
      return m === null ? null : { unique: Number(m[1]), k: Number(m[2]) }
    })
    .catch(() => null)
}

async function waitForSymbols(page, timeout = 30_000) {
  const deadline = Date.now() + timeout
  for (;;) {
    const c = await readCount(page)
    if (c !== null && c.unique > 0) return c
    if (Date.now() > deadline) throw new Error('receiver never decoded symbols')
    await page.waitForTimeout(200)
  }
}

async function waitForVerified(page, timeout = 180_000) {
  await waitForSelector(page, '.so-badge--ok', timeout, 'verified badge never appeared')
  await waitForSelector(page, '.badge-verified', 10_000, 'verified live badge never appeared')
}

// ============================================================
// main
// ============================================================
let browser = null
try {
  await ensureServer()
  browser = await chromium.launch({ headless: true })

  const heroFixture = {
    name: 'hero-demo.bin',
    mime: RANDOM_MIME,
    bytes: buildRandomBytes(64 * 1024, 1),
  }
  const bigFixture = {
    name: 'demo-data.bin',
    mime: RANDOM_MIME,
    bytes: buildRandomBytes(1024 * 1024, 2),
  }
  const phoneFixture = {
    name: 'hero-demo.bin',
    mime: RANDOM_MIME,
    bytes: buildRandomBytes(64 * 1024, 7),
  }

  // ---- 1. hero-broadcast.png + send-settings.png (1440x1440 @ dsf 2) ----
  {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 1440 },
      deviceScaleFactor: 2,
      baseURL: BASE,
    })
    const page = await context.newPage()
    await page.setViewportSize({ width: 1440, height: 1440 })
    await page.goto(BASE)
    await page.getByRole('button', { name: 'Send a file' }).click()
    await page.locator('input[type="file"]').setInputFiles({
      name: heroFixture.name,
      mimeType: heroFixture.mime,
      buffer: heroFixture.bytes,
    })
    await waitForButton(page, 'Begin broadcast', 20_000, 'settings panel never appeared')
    // bonus: settings panel shot before the broadcast starts
    await page.screenshot({ path: path.join(OUT, 'send-settings.png') })
    await page.getByRole('button', { name: 'Begin broadcast' }).click()
    await waitForCanvas(page)
    await waitForChips(page)
    await page.waitForTimeout(800) // let a QR frame settle / chips update
    await page.screenshot({ path: path.join(OUT, 'hero-broadcast.png') })
    console.log('[capture] hero-broadcast.png + send-settings.png')
    await context.close()
  }

  // ---- 2. phone-send.png (390x844 @ dsf 2, column3) ----
  {
    const context = await browser.newContext({
      viewport: { width: 390, height: 844 },
      deviceScaleFactor: 2,
      baseURL: BASE,
    })
    const page = await context.newPage()
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto(BASE)
    await page.getByRole('button', { name: 'Send a file' }).click()
    await page.locator('input[type="file"]').setInputFiles({
      name: phoneFixture.name,
      mimeType: phoneFixture.mime,
      buffer: phoneFixture.bytes,
    })
    await waitForButton(page, 'Begin broadcast', 20_000, 'settings panel never appeared')
    await page
      .getByRole('radiogroup', { name: 'Tile layout' })
      .locator('[data-layout="column3"]')
      .click()
    await page.getByRole('button', { name: 'Begin broadcast' }).click()
    await waitForCanvas(page)
    await waitForChips(page)
    await page.waitForTimeout(800)
    await page.screenshot({ path: path.join(OUT, 'phone-send.png') })
    console.log('[capture] phone-send.png')
    await context.close()
  }

  // ---- 3. receive-transferring.png + receive-verified.png (1280x860 @ dsf 2) ----
  {
    const context = await browser.newContext({
      viewport: { width: 1280, height: 860 },
      deviceScaleFactor: 2,
      baseURL: BASE,
    })
    const sender = await startSender(context, { width: 1440, height: 1440 }, bigFixture, {})
    const receiver = await openReceiver(context, sender)
    await startScanning(receiver)
    await waitForSymbols(receiver, 40_000)

    // mid-transfer: transferring chip visible and a partial (non-complete) count
    const deadline = Date.now() + 90_000
    for (;;) {
      const chip = await receiver
        .locator('.so-chip--transferring')
        .isVisible()
        .catch(() => false)
      const c = await readCount(receiver)
      if (chip && c !== null && c.k > 0 && c.unique / c.k >= 0.3 && c.unique / c.k <= 0.9) break
      if (Date.now() > deadline) throw new Error('never caught a mid-transfer state')
      await receiver.waitForTimeout(200)
    }
    await receiver.waitForTimeout(300) // let the overlay paint the latest stats
    await receiver.screenshot({ path: path.join(OUT, 'receive-transferring.png') })
    console.log('[capture] receive-transferring.png')

    await waitForVerified(receiver, 180_000)
    // The camera halts on completion (orchestrate.halt() stops the tracks), so
    // the stage goes dark; frame a tight composition around the completion UI.
    await receiver.setViewportSize({ width: 640, height: 560 })
    await receiver.waitForTimeout(400)
    await receiver.screenshot({ path: path.join(OUT, 'receive-verified.png') })
    console.log('[capture] receive-verified.png')
    await context.close()
  }

  // ---- 4. GIF source: receiver-page webm (480x800, recordVideo) ----
  {
    const context = await browser.newContext({
      viewport: { width: 480, height: 800 },
      deviceScaleFactor: 1,
      baseURL: BASE,
      recordVideo: { dir: TMP, size: { width: 480, height: 800 } },
    })
    // Hide the camera preview for the GIF source: the overlay glass is 85%
    // opaque, so the QR motion bleeds through and explodes GIF size. Decoding
    // is untouched (the video keeps playing), so the frame becomes a black
    // stage + the live stats overlay — which the compose step pairs with a
    // crisp static QR backdrop. addInitScript styles get purged by the app,
    // so inject directly once the receiver view (video element) is mounted.
    const sender = await startSender(context, { width: 1440, height: 1440 }, bigFixture, {})
    const receiver = await openReceiver(context, sender)
    await receiver.getByRole('button', { name: 'Receive a file' }).click()
    await receiver.addStyleTag({ content: 'video.camera-video{visibility:hidden !important}' })
    await receiver.getByRole('button', { name: 'Start scanning' }).click()
    await waitForSymbols(receiver, 40_000)
    // record ~9s of the transfer in progress (unique count climbing)
    await receiver.waitForTimeout(9500)
    const video = receiver.video()
    console.log('[capture] gif source recorded, closing context to finalize webm')
    await context.close()
    if (video === null) throw new Error('no video recorded')
    const webm = await video.path()
    console.log(`[capture] webm at ${webm}`)
  }

  console.log('[done] all captures complete')
} finally {
  if (browser !== null) await browser.close().catch(() => {})
  stopServer()
}

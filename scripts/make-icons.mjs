// Renders the app icons committed under public/: a dark rounded-square QR-ish
// glyph at 192x192, 512x512 and a maskable (full-bleed, content inside the
// safe zone) 512x512 variant. Deterministic seeded RNG — rerunning is stable.
// Usage: node scripts/make-icons.mjs  (writes public/icon-*.png)
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { PNG } from 'pngjs'

const BG = [0x0f, 0x11, 0x15] // #0f1115, matches manifest theme_color
const FG = [0xe8, 0xea, 0xed] // light modules
const GRID = 16
const PUBLIC_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'public')

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

// Finder pattern corners: top-left (0..6), top-right (9..15), bottom-left (0..6).
const FINDERS = [
  [0, 0],
  [9, 0],
  [0, 9],
]

function inFinder(gx, gy) {
  return FINDERS.some(([ox, oy]) => gx >= ox && gx <= ox + 6 && gy >= oy && gy <= oy + 6)
}

function finderCell(gx, gy) {
  // Light where neither the outer dark ring nor the central dark 3x3 sits.
  const x = gx % 9
  const y = gy % 9
  const dark = x === 0 || x === 6 || y === 0 || y === 6 || (x >= 2 && x <= 4 && y >= 2 && y <= 4)
  return dark ? 0 : 1
}

function buildGrid() {
  const rand = mulberry32(0xc0dec0de)
  const cells = []
  for (let gy = 0; gy < GRID; gy++) {
    for (let gx = 0; gx < GRID; gx++) {
      cells.push(inFinder(gx, gy) ? finderCell(gx, gy) : rand() < 0.45 ? 1 : 0)
    }
  }
  return cells
}

function outsideRoundedRect(x, y, size, radius) {
  const xr = size - 1 - radius
  const yr = size - 1 - radius
  // Clamp to the inner rect, then test the corner-arc distance (SDF).
  const cx = Math.min(Math.max(x, radius), xr)
  const cy = Math.min(Math.max(y, radius), yr)
  const dx = x - cx
  const dy = y - cy
  return dx * dx + dy * dy > radius * radius
}

function renderIcon(size, { contentScale, rounded, outName }) {
  const png = new PNG({ width: size, height: size })
  const inner = Math.round(size * contentScale)
  const module = Math.max(1, Math.floor(inner / GRID))
  const grid = module * GRID
  const offset = Math.floor((size - grid) / 2)
  const radius = rounded ? Math.round(size * 0.14) : 0
  const cells = buildGrid()

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const idx = (size * y + x) << 2
      if (rounded && outsideRoundedRect(x, y, size, radius)) {
        png.data[idx + 3] = 0
        continue
      }
      let on = 0
      if (x >= offset && y >= offset && x < offset + grid && y < offset + grid) {
        const gx = Math.floor((x - offset) / module)
        const gy = Math.floor((y - offset) / module)
        on = cells[gy * GRID + gx]
      }
      png.data[idx] = on ? FG[0] : BG[0]
      png.data[idx + 1] = on ? FG[1] : BG[1]
      png.data[idx + 2] = on ? FG[2] : BG[2]
      png.data[idx + 3] = 255
    }
  }
  writeFileSync(join(PUBLIC_DIR, outName), PNG.sync.write(png))
}

// Any icon: glyph fills the canvas, transparent rounded corners.
renderIcon(512, { contentScale: 1, rounded: true, outName: 'icon-512.png' })
renderIcon(192, { contentScale: 1, rounded: true, outName: 'icon-192.png' })
// Maskable: full-bleed background, glyph kept inside the ~80% safe zone.
renderIcon(512, { contentScale: 0.68, rounded: false, outName: 'icon-maskable-512.png' })

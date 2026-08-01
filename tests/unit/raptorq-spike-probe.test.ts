import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { beforeAll, describe, expect, it } from 'vitest'
// Bare `import 'raptorq'` fails: no `exports`/`main` in its package.json
// (only `module`), which Node and Vite 8 both refuse. Subpath import works
// everywhere — src/ codec wrapper must use `raptorq/raptorq.js`.
import init, { Decoder, Encoder } from 'raptorq/raptorq.js'

// No `exports`/`main` in the package, so the wasm binary is located by path and
// passed to `init()` explicitly — Node cannot fetch file:// and the default
// `init()` would try to.
const WASM_URL = new URL('../../node_modules/raptorq/raptorq_bg.wasm', import.meta.url)

function mulberry32(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a += 0x6d2b79f5
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function randomBytes(length: number, seed: number): Uint8Array {
  const rand = mulberry32(seed)
  const bytes = new Uint8Array(length)
  for (let i = 0; i < length; i++) {
    bytes[i] = Math.floor(rand() * 256)
  }
  return bytes
}

beforeAll(async () => {
  await init(readFileSync(fileURLToPath(WASM_URL)))
})

describe('raptorq@1.7.24 wasm round-trip under vitest (node env)', () => {
  it('initializes from explicit wasm bytes and round-trips 16 KiB', () => {
    const data = randomBytes(16 * 1024, 42)
    const mtu = 1028

    const encoder = Encoder.with_defaults(data, mtu)
    const packets = encoder.encode(4)

    const decoder = Decoder.with_defaults(BigInt(data.length), mtu)
    let out: Uint8Array | undefined
    for (const packet of packets) {
      out = decoder.decode(packet)
      if (out !== undefined) break
    }

    expect(out).toBeDefined()
    expect(out?.length).toBe(data.length)
    expect(out).toEqual(data)
  })

  it('decodes after losing 20% of packets (fountain property)', () => {
    const data = randomBytes(16 * 1024, 7)
    const mtu = 1028

    const encoder = Encoder.with_defaults(data, mtu)
    const k = encoder.encode(0).length
    // Enough repair symbols that 80% of (K+R) >= K survives a uniform 20% drop.
    const repair = Math.ceil((k * 0.2) / 0.8) + 8
    const packets = encoder.encode(repair)
    const dropped = new Set(packets.filter((_, i) => i % 5 === 0)) // drop every 5th

    const decoder = Decoder.with_defaults(BigInt(data.length), mtu)
    let out: Uint8Array | undefined
    let fed = 0
    for (const packet of packets) {
      if (dropped.has(packet)) continue
      fed++
      out = decoder.decode(packet)
      if (out !== undefined) break
    }

    expect(fed).toBeGreaterThanOrEqual(k)
    expect(out).toEqual(data)
  })
})

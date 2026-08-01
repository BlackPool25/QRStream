import { describe, expect, it } from 'vitest'
import { createRaptorqFountain } from '../../src/codec/fountain/raptorq'
import type { FountainFactory } from '../../src/codec/fountain/interface'

const MTU_1028 = 1028
const MTU_2052 = 2052

// One factory shared by every test: exercising reuse across many encoder/decoder
// pairs is itself part of the contract (wasm init is lazy and module-cached).
const factory: FountainFactory = createRaptorqFountain()

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

function shuffle<T>(items: readonly T[], rand: () => number): T[] {
  const result = items.slice()
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1))
    const a = result[i]
    const b = result[j]
    if (a !== undefined && b !== undefined) {
      result[i] = b
      result[j] = a
    }
  }
  return result
}

// Exact data length for K source symbols: symbol payload is mtu - 4.
function dataForK(k: number, mtu: number, seed: number): Uint8Array {
  return randomBytes(k * (mtu - 4), seed)
}

// vitest's toEqual is O(n^2) on big typed arrays (1MB takes seconds), so assert
// byte-identity with a single O(n) pass that fails on the first mismatch.
function expectBytesEqual(actual: Uint8Array | undefined, expected: Uint8Array): void {
  expect(actual).toBeDefined()
  if (actual === undefined) return
  expect(actual.length).toBe(expected.length)
  for (let i = 0; i < expected.length; i++) {
    if (actual[i] !== expected[i]) {
      expect(actual[i]).toBe(expected[i])
      return
    }
  }
}

describe('raptorq fountain wrapper (source-only round-trips, byte-identical)', () => {
  const cases = [
    { k: 10, mtu: MTU_1028, seed: 101 },
    { k: 100, mtu: MTU_1028, seed: 102 },
    { k: 1000, mtu: MTU_1028, seed: 103 },
    { k: 7000, mtu: MTU_1028, seed: 104 },
    { k: 10, mtu: MTU_2052, seed: 105 },
    { k: 100, mtu: MTU_2052, seed: 106 },
    { k: 1000, mtu: MTU_2052, seed: 107 },
    { k: 7000, mtu: MTU_2052, seed: 108 },
  ]
  for (const { k, mtu, seed } of cases) {
    it(`decodes K=${k} from source-only packets at mtu ${mtu}`, async () => {
      const data = dataForK(k, mtu, seed)
      const encoder = await factory.createEncoder(data, mtu)
      const decoder = await factory.createDecoder(data.length, mtu)
      let out: Uint8Array | undefined
      try {
        expect(encoder.sourceSymbolCount).toBe(k)
        for (const symbol of encoder.encodeSourceSymbols()) {
          out = decoder.decode(symbol.bytes)
          if (out !== undefined) break
        }
      } finally {
        encoder.dispose()
        decoder.dispose()
      }
      expectBytesEqual(out, data)
    })
  }

  it('round-trips a length that is not a multiple of the symbol size', async () => {
    const mtu = MTU_1028
    const data = randomBytes(100 * (mtu - 4) + 500, 601) // K = 101
    const encoder = await factory.createEncoder(data, mtu)
    const decoder = await factory.createDecoder(data.length, mtu)
    let out: Uint8Array | undefined
    try {
      expect(encoder.sourceSymbolCount).toBe(101)
      for (const symbol of encoder.encodeSourceSymbols()) {
        out = decoder.decode(symbol.bytes)
        if (out !== undefined) break
      }
    } finally {
      encoder.dispose()
      decoder.dispose()
    }
    expectBytesEqual(out, data)
  })
})

describe('raptorq fountain wrapper (loss resilience, ≥K distinct survive)', () => {
  const losses = [0.1, 0.2, 0.3]
  const cases = [
    { k: 1000, mtu: MTU_1028, seed: 201 },
    { k: 7000, mtu: MTU_1028, seed: 202 },
    { k: 100, mtu: MTU_2052, seed: 203 },
  ]
  for (const { k, mtu, seed } of cases) {
    for (const loss of losses) {
      it(`decodes K=${k} mtu=${mtu} after dropping ${Math.round(loss * 100)}% of all packets`, async () => {
        const data = dataForK(k, mtu, seed)
        const repair = Math.ceil((k * loss) / (1 - loss)) + 16
        const encoder = await factory.createEncoder(data, mtu)
        const decoder = await factory.createDecoder(data.length, mtu)
        let out: Uint8Array | undefined
        try {
          const pool = encoder.encodeRepair(repair)
          const drop = Math.floor(pool.length * loss)
          const kept = shuffle(pool, mulberry32(seed + Math.round(loss * 100))).slice(
            0,
            pool.length - drop,
          )
          expect(kept.length).toBeGreaterThanOrEqual(k)
          for (const symbol of kept) {
            out = decoder.decode(symbol.bytes)
            if (out !== undefined) break
          }
        } finally {
          encoder.dispose()
          decoder.dispose()
        }
        expectBytesEqual(out, data)
      })
    }
  }
})

describe('raptorq fountain wrapper (ordering, duplicates, determinism)', () => {
  it('decodes packets received out of order', async () => {
    const mtu = MTU_1028
    const data = dataForK(1000, mtu, 301)
    const encoder = await factory.createEncoder(data, mtu)
    const decoder = await factory.createDecoder(data.length, mtu)
    let out: Uint8Array | undefined
    try {
      const shuffled = shuffle(encoder.encodeSourceSymbols(), mulberry32(777))
      for (const symbol of shuffled) {
        out = decoder.decode(symbol.bytes)
        if (out !== undefined) break
      }
    } finally {
      encoder.dispose()
      decoder.dispose()
    }
    expectBytesEqual(out, data)
  })

  it('tolerates feeding every packet twice and keeps reporting the file', async () => {
    const mtu = MTU_1028
    const data = dataForK(100, mtu, 302)
    const encoder = await factory.createEncoder(data, mtu)
    const decoder = await factory.createDecoder(data.length, mtu)
    let out: Uint8Array | undefined
    try {
      const symbols = encoder.encodeSourceSymbols()
      for (let round = 0; round < 2; round++) {
        for (const symbol of symbols) {
          out = decoder.decode(symbol.bytes)
        }
      }
      expect(decoder.isComplete).toBe(true)
      const first = symbols[0]
      if (first !== undefined) {
        expectBytesEqual(decoder.decode(first.bytes), data)
      }
    } finally {
      encoder.dispose()
      decoder.dispose()
    }
    expectBytesEqual(out, data)
  })

  it('produces identical source packet bytes across two encoders', async () => {
    const mtu = MTU_1028
    const data = dataForK(100, mtu, 401)
    const encoderA = await factory.createEncoder(data, mtu)
    const encoderB = await factory.createEncoder(data, mtu)
    try {
      const a = encoderA.encodeSourceSymbols()
      const b = encoderB.encodeSourceSymbols()
      expect(a.length).toBe(b.length)
      for (let i = 0; i < a.length; i++) {
        const x = a[i]
        const y = b[i]
        if (x !== undefined && y !== undefined) {
          expect(x.esi).toBe(y.esi)
          expectBytesEqual(x.bytes, y.bytes)
        }
      }
    } finally {
      encoderA.dispose()
      encoderB.dispose()
    }
  })

  it('supports independent encoder/decoder pairs from the same factory concurrently', async () => {
    const mtu = MTU_1028
    const dataA = dataForK(10, mtu, 402)
    const dataB = dataForK(50, mtu, 403)
    const encoderA = await factory.createEncoder(dataA, mtu)
    const encoderB = await factory.createEncoder(dataB, mtu)
    const decoderA = await factory.createDecoder(dataA.length, mtu)
    const decoderB = await factory.createDecoder(dataB.length, mtu)
    let outA: Uint8Array | undefined
    let outB: Uint8Array | undefined
    try {
      for (const symbol of encoderA.encodeSourceSymbols()) {
        outA = decoderA.decode(symbol.bytes)
      }
      for (const symbol of encoderB.encodeSourceSymbols()) {
        outB = decoderB.decode(symbol.bytes)
      }
    } finally {
      encoderA.dispose()
      encoderB.dispose()
      decoderA.dispose()
      decoderB.dispose()
    }
    expectBytesEqual(outA, dataA)
    expectBytesEqual(outB, dataB)
  })
})

describe('raptorq fountain wrapper (boundary guards and contract)', () => {
  it('exposes symbolSize = mtu and esi = packet index for source symbols', async () => {
    const mtu = MTU_1028
    const data = dataForK(100, mtu, 701)
    const encoder = await factory.createEncoder(data, mtu)
    try {
      expect(encoder.symbolSize).toBe(mtu)
      expect(encoder.sourceSymbolCount).toBe(100)
      const symbols = encoder.encodeSourceSymbols()
      expect(symbols.length).toBe(100)
      symbols.forEach((symbol, index) => {
        expect(symbol.bytes.length).toBe(mtu)
        expect(symbol.esi).toBe(index)
      })
    } finally {
      encoder.dispose()
    }
  })

  it('rejects MTUs below the library minimum of 64', async () => {
    const data = new Uint8Array(256)
    await expect(factory.createEncoder(data, 40)).rejects.toThrow(RangeError)
    await expect(factory.createEncoder(data, 63)).rejects.toThrow(RangeError)
    await expect(factory.createDecoder(256, 40)).rejects.toThrow(RangeError)
  })

  it('rejects MTUs above 65535 (u16 overflow in the wasm layer)', async () => {
    const data = new Uint8Array(256)
    await expect(factory.createEncoder(data, 65536)).rejects.toThrow(RangeError)
    await expect(factory.createDecoder(256, 65536)).rejects.toThrow(RangeError)
  })

  it('encodes and decodes at the minimum MTU of 64', async () => {
    const mtu = 64
    const data = randomBytes(64, 501) // K = 1
    const encoder = await factory.createEncoder(data, mtu)
    const decoder = await factory.createDecoder(data.length, mtu)
    let out: Uint8Array | undefined
    try {
      expect(encoder.sourceSymbolCount).toBe(1)
      for (const symbol of encoder.encodeSourceSymbols()) {
        out = decoder.decode(symbol.bytes)
        if (out !== undefined) break
      }
    } finally {
      encoder.dispose()
      decoder.dispose()
    }
    expectBytesEqual(out, data)
  })

  it('decodes a single byte at MTU 1028', async () => {
    const mtu = MTU_1028
    const data = new Uint8Array([0xab])
    const encoder = await factory.createEncoder(data, mtu)
    const decoder = await factory.createDecoder(data.length, mtu)
    let out: Uint8Array | undefined
    try {
      expect(encoder.sourceSymbolCount).toBe(1)
      for (const symbol of encoder.encodeSourceSymbols()) {
        out = decoder.decode(symbol.bytes)
        if (out !== undefined) break
      }
    } finally {
      encoder.dispose()
      decoder.dispose()
    }
    expectBytesEqual(out, data)
  })

  it('rejects empty data (K would be 0 and unreconstructable)', async () => {
    await expect(factory.createEncoder(new Uint8Array(0), MTU_1028)).rejects.toThrow(RangeError)
    await expect(factory.createDecoder(0, MTU_1028)).rejects.toThrow(RangeError)
  })
})

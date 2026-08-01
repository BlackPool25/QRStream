import { describe, expect, it } from 'vitest'
import { SplitMix32 } from '../../src/codec/fountain/rng'

// Golden vectors generated from a Python arbitrary-precision reference and
// cross-verified with JS Math.imul. Both agree exactly on every value.
const GOLDEN_SEED_0 = [
  0x64625032, 0xd9c0799c, 0xaf362e10, 0x7fa88912, 0xc4671b39, 0xf1d2eee4, 0x867a4029, 0xa3772475,
  0xee3e862c, 0x88cc3672, 0x2de4afb5, 0x7e785fa2, 0x991e27d9, 0x8051c7f4, 0xb0c40637, 0xef6cfcab,
  0xaa9816a0, 0xbca2a091, 0xa60e7ff2, 0x511a119c, 0x5a3ab2d1, 0x39ecfb7c, 0x77ece360, 0xe25f65ce,
  0xf6abb0b7, 0x323e4fb2, 0xb7d452d7, 0x0d38dc18, 0xdebd2e34, 0xd4e554d8, 0x56c231bd, 0x57d5d6ba,
] as const

const GOLDEN_SEED_12345678 = [
  0xb1fb5107, 0x2c5fffd8, 0x83672faf, 0xa78b935c, 0x45fa27a7, 0xcf5ab5c4, 0x1838de5d, 0xb9b1de2c,
  0xe83b38ca, 0x31eefe1b, 0x343b028d, 0x25ea40aa, 0x3f9c89bd, 0x3968a70d, 0xa539500b, 0xf0c53c34,
  0x54fbba06, 0x5e3d6d85, 0x65988249, 0x439b0d5e, 0xb36bd85b, 0xdb0f2f2a, 0xa5c56cf1, 0xe293d959,
  0x30c68d34, 0xeb3f5fdc, 0xefd6f415, 0x0ef0aeac, 0xd75e1792, 0x518c30b9, 0xaa9b46a4, 0x4c41e473,
] as const

const first = (count: number, seed: number): readonly number[] => {
  const rng = new SplitMix32(seed)
  const out: number[] = []
  for (let i = 0; i < count; i++) out.push(rng.next())
  return out
}

describe('SplitMix32', () => {
  it('produces the golden sequence for seed 0x0', () => {
    expect(first(GOLDEN_SEED_0.length, 0x0)).toEqual(GOLDEN_SEED_0)
  })

  it('produces the golden sequence for seed 0x12345678', () => {
    expect(first(GOLDEN_SEED_12345678.length, 0x12345678)).toEqual(GOLDEN_SEED_12345678)
  })

  it('returns uint32 values in [0, 2^32)', () => {
    const rng = new SplitMix32(0x12345678)
    for (let i = 0; i < 1000; i++) {
      const v = rng.next()
      expect(v).toBeGreaterThanOrEqual(0)
      expect(v).toBeLessThanOrEqual(0xffffffff)
      expect(Number.isInteger(v)).toBe(true)
    }
  })

  it('int(maxExclusive) always lands in [0, maxExclusive)', () => {
    const rng = new SplitMix32(0x12345678)
    for (let i = 0; i < 1000; i++) {
      const v = rng.int(7)
      expect(v).toBeGreaterThanOrEqual(0)
      expect(v).toBeLessThan(7)
    }
  })

  it('distributes int(10) uniformly across 10 buckets', () => {
    const rng = new SplitMix32(0x12345678)
    const buckets = new Array(10).fill(0)
    for (let i = 0; i < 10000; i++) buckets[rng.int(10)]++
    for (const count of buckets) {
      expect(count).toBeGreaterThanOrEqual(800)
      expect(count).toBeLessThanOrEqual(1200)
    }
  })

  it('two instances with the same seed produce identical sequences', () => {
    expect(first(1000, 42)).toEqual(first(1000, 42))
  })

  it('different seeds produce different sequences', () => {
    expect(first(32, 7)).not.toEqual(first(32, 8))
  })
})

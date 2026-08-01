import { describe, expect, it } from 'vitest'
import { compress, decompress, type CompressedResult } from '../../src/codec/compression/deflate'

// Deterministic PRNG so the "random" fixture is reproducible across runs.
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

function repeatedByte(byte: number, length: number): Uint8Array {
  const bytes = new Uint8Array(length)
  bytes.fill(byte)
  return bytes
}

function mixedText(length: number, seed: number): Uint8Array {
  const rand = mulberry32(seed)
  const words = ['the', 'quick', 'brown', 'fox', 'jumps', 'over', 'lazy', 'dog', 'qr', 'transfer']
  const bytes = new Uint8Array(length)
  for (let i = 0; i < length; i++) {
    if (i % 32 === 0) {
      // `rand() < 1` bounds the index, but noUncheckedIndexedAccess can't see it.
      const word = words[Math.floor(rand() * words.length)] ?? 'qr'
      for (let j = 0; j < word.length && i + j < length; j++) {
        bytes[i + j] = word.charCodeAt(j)
      }
      i += word.length - 1
    } else {
      bytes[i] = 32 + Math.floor(rand() * 95) // printable ASCII
    }
  }
  return bytes
}

function expectRoundTrip(input: Uint8Array): void {
  const result = compress(input)
  const restored = decompress(result)
  expect(restored.length).toBe(input.length)
  expect(restored).toEqual(input)
}

function expectSameBytes(a: Uint8Array, b: Uint8Array): void {
  expect(a.length).toBe(b.length)
  expect(a).toEqual(b)
}

describe('compress / decompress', () => {
  it('round-trips an empty input and reports compressed=false', () => {
    const input = new Uint8Array(0)
    const result = compress(input)
    expect(result.compressed).toBe(false)
    expect(result.data.length).toBe(0)
    expectRoundTrip(input)
  })

  it('round-trips a single byte', () => {
    const input = new Uint8Array([42])
    expectRoundTrip(input)
  })

  it('compresses highly compressible repeated data and round-trips', () => {
    const input = repeatedByte('a'.charCodeAt(0), 10 * 1024)
    const result = compress(input)
    expect(result.compressed).toBe(true)
    expect(result.data.length).toBeLessThan(input.length)
    expectRoundTrip(input)
  })

  it('skips compression when deflate would not shrink the data', () => {
    const input = randomBytes(10 * 1024, 0xc0ffee)
    const result = compress(input)
    expect(result.compressed).toBe(false)
    expect(result.data).toBe(input)
    expectRoundTrip(input)
  })

  it('round-trips 100KB of mixed text', () => {
    const input = mixedText(100 * 1024, 7)
    expectRoundTrip(input)
  })

  it('is deterministic: identical input produces identical compressed bytes', () => {
    const input = repeatedByte('a'.charCodeAt(0), 10 * 1024)
    const first = compress(input)
    const second = compress(input)
    expect(first.compressed).toBe(second.compressed)
    if (first.compressed && second.compressed) {
      expectSameBytes(first.data, second.data)
    }
  })

  it('decompress returns the original reference on the non-compressed path', () => {
    const input = randomBytes(10 * 1024, 0xdeadbeef)
    const result: CompressedResult = { data: input, compressed: false }
    const restored = decompress(result)
    expect(restored).toBe(input)
    expectSameBytes(restored, input)
  })

  it('decompress inflates the compressed path back to the original bytes', () => {
    const input = repeatedByte('a'.charCodeAt(0), 10 * 1024)
    const result = compress(input)
    expect(result.compressed).toBe(true)
    const restored = decompress(result)
    expectSameBytes(restored, input)
  })
})

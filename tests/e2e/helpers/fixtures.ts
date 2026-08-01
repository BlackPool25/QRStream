import { createHash } from 'node:crypto'

/** A deterministic fixture: real bytes, a name, and the mime the receiver must preserve. */
export interface TransferFixture {
  readonly name: string
  readonly mime: string
  readonly bytes: Buffer
}

/** Deterministic PRNG (mulberry32) — fixtures are reproducible across runs. */
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

/** Incompressible random bytes — exercises the sender's no-compression path. */
export function buildRandomBytes(size: number, seed: number): Buffer {
  const rand = mulberry32(seed)
  const bytes = Buffer.alloc(size)
  for (let i = 0; i < size; i++) {
    bytes[i] = Math.floor(rand() * 256)
  }
  return bytes
}

/** 37-char alphabet keeps entropy below 8 bits/byte, so deflate shrinks it. */
const TEXT_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789 .,:;-'

/** Seeded compressible text — exercises the sender deflate + receiver inflate path. */
export function buildCompressibleText(size: number, seed: number): Buffer {
  const rand = mulberry32(seed)
  const bytes = Buffer.alloc(size)
  for (let i = 0; i < size; i++) {
    bytes[i] = TEXT_ALPHABET.charCodeAt(Math.floor(rand() * TEXT_ALPHABET.length))
  }
  return bytes
}

/** Independent SHA-256 over `bytes` — the hash the receiver recomputes to verify. */
export function sha256Hex(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex')
}

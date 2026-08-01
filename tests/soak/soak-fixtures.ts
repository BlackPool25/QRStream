/**
 * Soak fixtures: deterministic payload generators and pure helpers shared by
 * the matrix suite and the FrameBuffer end-to-end test. Everything here is
 * seeded and reproducible so a failing matrix cell reproduces byte-for-byte.
 */

export type PayloadKind = 'random' | 'text' | 'zeros'

export interface SoakSize {
  readonly name: string
  readonly bytes: number
}

/** Deterministic PRNG (mulberry32) — same generator the raptorq spike uses. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a += 0x6d2b79f5
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/**
 * O(n) fail-fast byte comparison. vitest's toEqual is O(n^2) on big
 * Uint8Arrays (7MB -> ~23s), so the soak compares with a single pass that
 * returns on the first differing byte.
 */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false
  }
  return true
}

/** Seeded Fisher-Yates shuffle (in-place on a copy). */
export function shuffle<T>(items: readonly T[], rand: () => number): T[] {
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

/**
 * Payload generators — one per S5 scenario class:
 *  - random: incompressible (PNG/JPEG-equivalent), exercises the
 *    compressed=false path.
 *  - text:   repetitive lorem with per-line variation, deflates well.
 *  - zeros:  max-compressible.
 */
export function makePayload(
  kind: PayloadKind,
  size: number,
  seed: number,
): Uint8Array<ArrayBuffer> {
  switch (kind) {
    case 'random': {
      const rand = mulberry32(seed)
      const bytes = new Uint8Array(size)
      for (let i = 0; i < size; i++) bytes[i] = Math.floor(rand() * 256)
      return bytes
    }
    case 'zeros':
      return new Uint8Array(size)
    case 'text': {
      const rand = mulberry32(seed)
      const bytes = new Uint8Array(size)
      const encoder = new TextEncoder()
      let pos = 0
      let line = 0
      while (pos < size) {
        const variation = Math.floor(rand() * 10_000)
        const lineBytes = encoder.encode(
          `${line}: The quick brown fox jumps over the lazy dog (v${variation}). `,
        )
        const chunk = Math.min(lineBytes.length, size - pos)
        bytes.set(lineBytes.subarray(0, chunk), pos)
        pos += chunk
        line++
      }
      return bytes
    }
  }
}

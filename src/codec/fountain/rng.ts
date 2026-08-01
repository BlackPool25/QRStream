/**
 * Deterministic integer-only PRNG (splitmix32).
 *
 * Pure uint32 arithmetic (no Math.random / Math.log) so sequences are
 * bit-identical across JS engines — used to drive reproducible RaptorQ
 * packet schedules. `Math.imul` is required for the two mix multiplications:
 * a plain `*` would round through IEEE-754 doubles (products exceed 2^53),
 * desyncing across engines and from reference implementations.
 */
export class SplitMix32 {
  private state: number

  constructor(seed: number) {
    this.state = seed >>> 0
  }

  /** Next uint32 in [0, 2^32). */
  next(): number {
    this.state = (this.state + 0x9e3779b9) >>> 0
    let z = this.state
    z = Math.imul(z ^ (z >>> 16), 0x21f0aaad)
    z = Math.imul(z ^ (z >>> 15), 0x735a2d97)
    z = z ^ (z >>> 15)
    return z >>> 0
  }

  /** Uniform int in [0, maxExclusive) via modulo of a uint32 draw. */
  int(maxExclusive: number): number {
    return this.next() % maxExclusive
  }
}

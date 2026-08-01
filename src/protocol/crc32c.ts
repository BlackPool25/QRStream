/**
 * CRC-32C (Castagnoli) over Uint8Array.
 * Reflected polynomial 0x1EDC6F41 (reflected form 0x82F63B78), as used by
 * RFC 3720 (iSCSI). Table-driven, verified against the RFC 3720 check value
 * crc32c("123456789") = 0xE3069283.
 */

const POLY = 0x82f63b78

const TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? POLY ^ (c >>> 1) : c >>> 1
    }
    table[n] = c >>> 0
  }
  return table
})()

/** CRC-32C of a whole buffer, returned as an unsigned 32-bit number. */
export function crc32c(data: Uint8Array): number {
  return new Crc32c().update(data).finalize()
}

/**
 * Streaming CRC-32C for chunked frames: call update() per chunk, then
 * finalize(). Results are identical to one-shot crc32c() over the
 * concatenated input.
 */
export class Crc32c {
  private crc = 0xffffffff

  update(data: Uint8Array): this {
    let crc = this.crc
    for (let i = 0; i < data.length; i++) {
      // TABLE index is bounded to [0, 255] by the mask; table is fully
      // initialized above, so the non-null assertion is an invariant, not a cast.
      crc = TABLE[(crc ^ data[i]!) & 0xff]! ^ (crc >>> 8)
    }
    this.crc = crc
    return this
  }

  finalize(): number {
    return (this.crc ^ 0xffffffff) >>> 0
  }
}

import { deflate, inflate } from 'pako'

export interface CompressedResult {
  data: Uint8Array
  compressed: boolean
}

const DEFLATE_LEVEL = 6

/**
 * Best-effort deflate compression. Compresses only when it actually shrinks
 * the payload: media like PNG/JPEG/MP4 are already compressed, and deflate
 * would only grow them, so the original bytes are returned untouched and the
 * `compressed` flag (which drives the frame-header flag bit) stays false.
 */
export function compress(bytes: Uint8Array): CompressedResult {
  if (bytes.length === 0) {
    return { data: bytes, compressed: false }
  }
  const deflated = new Uint8Array(deflate(bytes, { level: DEFLATE_LEVEL }))
  if (deflated.length >= bytes.length) {
    return { data: bytes, compressed: false }
  }
  return { data: deflated, compressed: true }
}

export function decompress(result: CompressedResult): Uint8Array {
  if (!result.compressed) {
    return result.data
  }
  return new Uint8Array(inflate(result.data))
}

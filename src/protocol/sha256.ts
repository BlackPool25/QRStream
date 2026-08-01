/**
 * SHA-256 via WebCrypto (crypto.subtle.digest — available on Node 22+ and in
 * browsers). Used to fingerprint the original file bytes so the receiver can
 * verify reassembled output.
 */

/**
 * SHA-256 of the input bytes as a lowercase 64-char hex string.
 * WebCrypto requires an ArrayBuffer-backed view (no SharedArrayBuffer), so
 * the parameter is typed as `Uint8Array<ArrayBuffer>`; callers pass fresh
 * buffers from File.arrayBuffer()/TextEncoder, which are already that shape.
 */
export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  const view = new Uint8Array(digest)
  let hex = ''
  for (let i = 0; i < view.length; i++) {
    hex += view[i]!.toString(16).padStart(2, '0')
  }
  return hex
}

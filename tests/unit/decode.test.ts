import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import qrcodegen from '@ribpay/qr-code-generator'
import { beforeAll, describe, expect, it } from 'vitest'
import { decodeImageData, prepareDecodeModule } from '../../src/receiver/decode'
import { poolSize } from '../../src/receiver/pool'

beforeAll(async () => {
  // In Node there is no server to serve the .wasm from, so inject the binary
  // from node_modules into the zxing module (browser uses the default serve path).
  const require = createRequire(import.meta.url)
  const wasmPath = require.resolve('zxing-wasm/reader/zxing_reader.wasm')
  const wasmBuffer = readFileSync(wasmPath)
  const wasmBinary = wasmBuffer.buffer.slice(
    wasmBuffer.byteOffset,
    wasmBuffer.byteOffset + wasmBuffer.byteLength,
  )
  await prepareDecodeModule({ wasmBinary })
})

interface RenderedQr {
  data: Uint8ClampedArray<ArrayBuffer>
  width: number
  height: number
}

/** Renders a binary payload to a white-background RGBA QR image, in-test. */
function renderQr(payload: Uint8Array, scale: number): RenderedQr {
  const qr = qrcodegen.QrCode.encodeBinary(Array.from(payload), qrcodegen.QrCode.Ecc.LOW)
  const margin = Math.max(4, Math.floor(qr.size * 0.08))
  const total = qr.size * scale + margin * 2
  const data = new Uint8ClampedArray(total * total * 4)
  for (let y = 0; y < total; y++) {
    for (let x = 0; x < total; x++) {
      const moduleX = Math.floor((x - margin) / scale)
      const moduleY = Math.floor((y - margin) / scale)
      const dark =
        moduleX >= 0 &&
        moduleY >= 0 &&
        moduleX < qr.size &&
        moduleY < qr.size &&
        qr.getModule(moduleX, moduleY)
      const value = dark ? 0 : 255
      const offset = (y * total + x) * 4
      data[offset] = value
      data[offset + 1] = value
      data[offset + 2] = value
      data[offset + 3] = 255
    }
  }
  return { data, width: total, height: total }
}

describe('decodeImageData', () => {
  it.each([100, 1024, 2048])('recovers a %d-byte binary payload byte-identically', async (n) => {
    const payload = new Uint8Array(n).map((_, index) => (index * 7 + 3) % 251)
    const { data, width, height } = renderQr(payload, n > 1000 ? 4 : 8)

    const results = await decodeImageData(data, width, height)

    expect(results.length).toBe(1)
    expect(results[0]?.bytes).toEqual(payload)
  })

  it('decodes from a plain Uint8Array buffer, not only Uint8ClampedArray', async () => {
    const payload = new Uint8Array(256).map((_, index) => index % 251)
    const { data, width, height } = renderQr(payload, 6)
    const plain = new Uint8Array(data)

    const results = await decodeImageData(plain, width, height)

    expect(results[0]?.bytes).toEqual(payload)
  })

  it('reports the four corner positions of the detected barcode', async () => {
    const payload = new Uint8Array(64).map((_, index) => index)
    const { data, width, height } = renderQr(payload, 8)

    const results = await decodeImageData(data, width, height)

    const position = results[0]?.position
    expect(position).toBeDefined()
    expect(position?.topLeft).toEqual({ x: expect.any(Number), y: expect.any(Number) })
    expect(position?.topRight).toEqual({ x: expect.any(Number), y: expect.any(Number) })
    expect(position?.bottomLeft).toEqual({ x: expect.any(Number), y: expect.any(Number) })
    expect(position?.bottomRight).toEqual({ x: expect.any(Number), y: expect.any(Number) })
  })

  it('returns an empty array when the image contains no barcode', async () => {
    const total = 200
    const data = new Uint8ClampedArray(total * total * 4).fill(255)

    const results = await decodeImageData(data, total, total)

    expect(results).toEqual([])
  })
})

describe('poolSize', () => {
  it('caps the pool at 4 workers for 8-way hardware concurrency', () => {
    expect(poolSize(8)).toBe(4)
  })

  it('keeps a floor of 2 workers for 2-way hardware concurrency', () => {
    expect(poolSize(2)).toBe(2)
  })

  it('floors a single-core device up to 2 workers', () => {
    expect(poolSize(1)).toBe(2)
  })

  it('never returns fewer than 2 workers when concurrency is unknown', () => {
    expect(poolSize(undefined)).toBeGreaterThanOrEqual(2)
  })
})

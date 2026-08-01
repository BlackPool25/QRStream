import { prepareZXingModule, readBarcodes, type ReadResult } from 'zxing-wasm/reader'

export interface DecodeResultPoint {
  x: number
  y: number
}

export interface DecodeResultPosition {
  topLeft: DecodeResultPoint
  topRight: DecodeResultPoint
  bottomLeft: DecodeResultPoint
  bottomRight: DecodeResultPoint
}

/**
 * RGBA pixel buffer. Under TS 6 the typed arrays are no longer mutually
 * assignable, and both shapes arrive here: `Uint8ClampedArray` from
 * `canvas.getImageData()` and a plain `Uint8Array` after postMessage transfer.
 */
export type RgbaBuffer = Uint8Array<ArrayBuffer> | Uint8ClampedArray<ArrayBuffer>

/**
 * A normalized decode result. `bytes` is preferred over `text`: transfer
 * payloads are raw bytes and zxing-wasm decodes both, so the UI layer only
 * ever touches these shapes — never zxing directly.
 */
export interface DecodeResult {
  text?: string
  bytes?: Uint8Array
  position?: DecodeResultPosition
}

export interface PrepareDecodeModuleOptions {
  /**
   * Raw zxing_reader.wasm bytes. Required in Node (tests / CI) where the
   * package's default CDN `locateFile` cannot be fetched.
   */
  wasmBinary?: ArrayBuffer
  /**
   * URL the runtime should fetch the .wasm from. Injected by the worker from
   * a Vite `?url` asset so the offline PWA serves the binary itself instead
   * of a third-party CDN.
   */
  wasmUrl?: string
}

let decodeModulePromise: Promise<void> | undefined

/**
 * One-time, lazily-cached zxing module initialization. Safe to call from any
 * realm (main thread, worker, Node test); the first call wins and every later
 * call reuses its promise. Must complete before the first decode.
 */
export function prepareDecodeModule(options: PrepareDecodeModuleOptions = {}): Promise<void> {
  if (decodeModulePromise === undefined) {
    decodeModulePromise = initDecodeModule(options)
  }
  return decodeModulePromise
}

async function initDecodeModule(options: PrepareDecodeModuleOptions): Promise<void> {
  const { wasmBinary, wasmUrl } = options
  if (wasmBinary !== undefined) {
    prepareZXingModule({ overrides: { wasmBinary } })
  } else if (wasmUrl !== undefined) {
    prepareZXingModule({
      overrides: {
        locateFile: (path: string, scriptDirectory: string) =>
          path.endsWith('.wasm') ? wasmUrl : scriptDirectory + path,
      },
    })
  }
  // Neither override: the package default locateFile (CDN / dev server) is used.
}

/**
 * Decodes QR codes from raw RGBA pixels (`width * height * 4` bytes, row
 * major). Pass `wasmBinary` via {@link prepareDecodeModule} first when running
 * in Node. Returns an empty array when no QR code is found.
 */
export async function decodeImageData(
  data: RgbaBuffer,
  width: number,
  height: number,
): Promise<DecodeResult[]> {
  await prepareDecodeModule()
  const rgba = toRgbaPixels(data)
  // zxing duck-types ImageData to `{ data, width, height }`; the DOM type in
  // TS 6 additionally requires colorSpace, which the reader never touches.
  const image = { data: rgba, width, height } as ImageData
  const results = await readBarcodes(image, { formats: ['QRCode'] })
  return results.map(toDecodeResult)
}

function toRgbaPixels(data: RgbaBuffer): Uint8ClampedArray<ArrayBuffer> {
  if (data instanceof Uint8ClampedArray) {
    return data
  }
  // Zero-copy view over the same bytes; readBarcodes expects Uint8ClampedArray.
  return new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength)
}

function toDecodeResult(result: ReadResult): DecodeResult {
  const decoded: DecodeResult = {}
  if (result.text !== '') {
    decoded.text = result.text
  }
  if (result.bytes.length > 0) {
    decoded.bytes = result.bytes
  }
  const { topLeft, topRight, bottomLeft, bottomRight } = result.position
  decoded.position = {
    topLeft: { x: topLeft.x, y: topLeft.y },
    topRight: { x: topRight.x, y: topRight.y },
    bottomLeft: { x: bottomLeft.x, y: bottomLeft.y },
    bottomRight: { x: bottomRight.x, y: bottomRight.y },
  }
  return decoded
}

/**
 * Decode worker: receives RGBA frames, decodes QR codes with the lazily
 * initialized zxing wasm module, and posts results back with `bytes`
 * transferred (not copied). One worker per file is cheap; the pool in
 * `src/receiver/pool.ts` manages several.
 */
import zxingWasmUrl from 'zxing-wasm/reader/zxing_reader.wasm?url'
import { decodeImageData, prepareDecodeModule, type DecodeResult } from '../receiver/decode'
import { type DecodeRequest, type DecodeWorkerResponse } from '../receiver/pool'

declare const self: DedicatedWorkerGlobalScope

// Initialize the wasm module once, before the first message can arrive. In the
// browser the module is served from the app's own build (offline-friendly)
// rather than the package's default CDN locateFile.
const decodeModuleReady = prepareDecodeModule({ wasmUrl: zxingWasmUrl })

self.onmessage = (event: MessageEvent<DecodeRequest>) => {
  const { id, data, width, height } = event.data
  void respond(id, decodeImageData(data, width, height))
}

async function respond(id: number, decode: Promise<DecodeResult[]>): Promise<void> {
  try {
    await decodeModuleReady
    const results = await decode
    self.postMessage({ id, results } satisfies DecodeWorkerResponse, {
      transfer: transferableBytes(results),
    })
  } catch (error) {
    self.postMessage({ id, results: [], error: messageOf(error) })
  }
}

function transferableBytes(results: DecodeResult[]): Transferable[] {
  const transfer: Transferable[] = []
  for (const result of results) {
    if (result.bytes !== undefined) {
      transfer.push(result.bytes.buffer as ArrayBuffer)
    }
  }
  return transfer
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

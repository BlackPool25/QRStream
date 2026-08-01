/**
 * Single source of truth for the codec wasm asset URLs.
 *
 * Both files are imported with Vite's `?url` suffix, which resolves to a
 * content-hashed asset in dist/assets/ on build (see docs/decisions/raptorq.md
 * for the browser load pattern). Importing them here keeps them in the build
 * graph, so vite-plugin-pwa's generateSW precache manifest includes them —
 * the app works with zero network after first load.
 *
 * Consumer contract: `fetch(url)` then hand the bytes to the wasm `init()`
 * (zxing) / `init()` glue (raptorq). These URLs are stable hashed asset URLs,
 * safe to keep across module reloads.
 */
import raptorqWasmUrl from 'raptorq/raptorq_bg.wasm?url'
import zxingReaderWasmUrl from 'zxing-wasm/reader/zxing_reader.wasm?url'

export const wasmAssets = {
  /** ZXing-C++ QR decode wasm (~1.02 MiB). */
  zxingReader: zxingReaderWasmUrl,
  /** RaptorQ fountain-codec wasm (~235 KiB). */
  raptorq: raptorqWasmUrl,
} as const

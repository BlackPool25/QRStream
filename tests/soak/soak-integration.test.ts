/**
 * Soak FrameBuffer end-to-end test — the camera scan path at 1MB.
 *
 * Unlike the matrix (which drives the Reassembler directly with symbol
 * arrays), this test feeds REAL wire frames — prepared by prepareTransfer —
 * through the FrameBuffer with shuffle + duplicates, then hands the buffer's
 * deduped symbols to the Reassembler. It proves the dedup -> reassemble path
 * holds at scale, not just the codec.
 *
 * The matrix report is owned by soak.test.ts; this file asserts only.
 */

import { describe, expect, it } from 'vitest'
import { parseMetadataFrame } from '../../src/protocol/metadata'
import { FrameBuffer } from '../../src/receiver/frames'
import { Reassembler } from '../../src/receiver/reassemble'
import { prepareTransfer, repairFrames } from '../../src/sender/pipeline'
import { bytesEqual, makePayload, mulberry32, shuffle } from './soak-fixtures'

describe('soak — FrameBuffer end-to-end (camera scan path at 1MB)', () => {
  it(
    'reassembles a 1MB file through FrameBuffer with shuffle, duplicates and repair',
    { timeout: 120_000 },
    async () => {
      const original = makePayload('random', 1024 * 1024, 0xb0a7)
      const prepared = await prepareTransfer({
        file: original,
        filename: 'buffer-1mb.bin',
        mime: 'application/octet-stream',
      })
      try {
        const metadata = parseMetadataFrame(prepared.metaFrames[0]!)
        const k = metadata.k
        const repair = repairFrames(prepared, Math.ceil(k * 0.3))
        const stream = [...prepared.dataFrames, ...repair]

        // Shuffle within 200-frame windows and duplicate every 7th frame.
        const rand = mulberry32(0xb0a7)
        const windowed: Uint8Array[] = []
        for (let i = 0; i < stream.length; i += 200) {
          windowed.push(...shuffle(stream.slice(i, i + 200), rand))
        }
        const feedStream: Uint8Array[] = []
        windowed.forEach((frame, i) => {
          feedStream.push(frame)
          if (i % 7 === 0) feedStream.push(frame)
        })

        const buffer = new FrameBuffer()
        const metaResult = buffer.feed(prepared.metaFrames[0]!)
        expect(metaResult.status).toBe('ok')
        for (const frame of feedStream) {
          buffer.feed(frame)
        }

        expect(buffer.sessionId).toBe(metadata.sessionId)
        expect(buffer.metadata).toEqual(metadata)
        expect(buffer.uniqueSymbolCount).toBeGreaterThanOrEqual(k)

        const reassembler = new Reassembler({ mtu: metadata.mtu })
        await reassembler.start(metadata, buffer.symbols(), buffer.symbolEsiSet())
        expect(reassembler.isComplete).toBe(true)
        const result = await reassembler.finish()
        expect(result.verified).toBe(true)
        expect(bytesEqual(result.bytes, original)).toBe(true)
        expect(result.sha256).toBe(metadata.fileSHA256)
        reassembler.reset()
      } finally {
        prepared.encoder.dispose()
      }
    },
  )
})

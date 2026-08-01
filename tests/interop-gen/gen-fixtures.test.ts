/**
 * PWA↔Flutter wire-compatibility fixture generator (Wave 0, T0.4).
 *
 * Runs the REAL sender pipeline (prepareTransfer → repairFrames) against three
 * deterministic inputs and COMMITS the resulting wire bytes under
 * flutter_app/core/test/fixtures/<name>/, so the Rust crate test (T2.2) and
 * the Dart FrameBuffer→Reassembler test (T4.4) can prove byte-level interop
 * without re-running Node.
 *
 * Committed file formats:
 *   original.bin   raw input bytes fed to the pipeline
 *   payload.bin    exact post-deflate bytes fed to the RaptorQ encoder
 *                  (info.compressedSize bytes; equals original.bin when
 *                  compressed:false)
 *   deflate.bin    the compress() output — identical to payload.bin by
 *                  construction (compress() returns the original bytes
 *                  unchanged when deflate would not shrink them)
 *   meta.frame     the single META wire frame, verbatim
 *   data.frames    all k DATA frames, each prefixed with a 4-byte BE length
 *                  (consumers split on [u32BE len][frame bytes]…)
 *   repair.frames  20 repair DATA frames, same length-prefixed format
 *   manifest.json  wire parameters + SHA-256 fingerprints of the bins
 *
 * NOTE: sessionId is random per run (generateSessionId), so re-running this
 * generator rewrites every frame; the seeds below keep the CONTENT
 * deterministic. Re-run only when the wire format changes.
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { compress } from '../../src/codec/compression/deflate'
import { TYPE_DATA } from '../../src/protocol/constants'
import { parseMetadataFrame } from '../../src/protocol/metadata'
import { decodeFrame } from '../../src/protocol/wire'
import { prepareTransfer, repairFrames } from '../../src/sender/pipeline'
import { buildCompressibleText, buildRandomBytes, sha256Hex } from '../e2e/helpers/fixtures'

/** Where the committed fixtures live (flutter_app/core/test/fixtures). */
const FIXTURES_ROOT = fileURLToPath(
  new URL('../../flutter_app/core/test/fixtures/', import.meta.url),
)

/** Number of repair DATA frames emitted per fixture. */
const REPAIR_COUNT = 20

interface FixtureCase {
  readonly name: string
  readonly filename: string
  readonly mime: string
  readonly bytes: () => Uint8Array
}

const CASES: readonly FixtureCase[] = [
  {
    name: 'random-1k',
    filename: 'random-1k.bin',
    mime: 'application/octet-stream',
    bytes: () => buildRandomBytes(1024, 5),
  },
  {
    name: 'text-256k',
    filename: 'text-256k.txt',
    mime: 'text/plain',
    bytes: () => buildCompressibleText(256 * 1024, 4),
  },
  {
    name: 'random-64k',
    filename: 'random-64k.bin',
    mime: 'application/octet-stream',
    bytes: () => buildRandomBytes(64 * 1024, 1),
  },
]

function firstOrThrow<T>(items: readonly T[]): T {
  const item = items[0]
  if (item === undefined) throw new Error('expected a non-empty array')
  return item
}

/** Serialize frames as [u32BE len][frame bytes]… — the on-disk format. */
function lengthPrefixed(frames: readonly Uint8Array[]): Uint8Array {
  const total = frames.reduce((sum, frame) => sum + 4 + frame.length, 0)
  const out = new Uint8Array(total)
  const view = new DataView(out.buffer)
  let offset = 0
  for (const frame of frames) {
    view.setUint32(offset, frame.length, false)
    offset += 4
    out.set(frame, offset)
    offset += frame.length
  }
  return out
}

/** Split the on-disk [u32BE len][frame bytes]… stream back into frames. */
function splitLengthPrefixed(bytes: Uint8Array): Uint8Array[] {
  const frames: Uint8Array[] = []
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let offset = 0
  while (offset < bytes.length) {
    const length = view.getUint32(offset, false)
    offset += 4
    frames.push(bytes.slice(offset, offset + length))
    offset += length
  }
  return frames
}

describe.each(CASES)('fixture $name', (fixture) => {
  it('writes a self-consistent, read-back-verified fixture set', async () => {
    // Given — deterministic input from the same helpers the e2e suite uses.
    const original = fixture.bytes()

    // When — the real sender pipeline (compress → RaptorQ → wire frames).
    const transfer = await prepareTransfer({
      file: original,
      filename: fixture.filename,
      mime: fixture.mime,
    })
    try {
      const { info, dataFrames, metaFrames } = transfer
      const payload = compress(original).data
      const repairs = repairFrames(transfer, REPAIR_COUNT)

      // Then — integrity before anything touches the disk.
      expect(payload.length).toBe(info.compressedSize)
      expect(dataFrames.length).toBe(info.k)
      expect(info.fileSHA256).toBe(sha256Hex(original))
      expect(info.symbolSize).toBe(info.mtu)
      expect(metaFrames.length).toBe(1)
      expect(repairs.length).toBe(REPAIR_COUNT)

      const firstFrame = decodeFrame(firstOrThrow(dataFrames))
      expect(firstFrame.payload[0]).toBe(0) // SBN of the first source block

      for (const [esi, frameBytes] of dataFrames.entries()) {
        const frame = decodeFrame(frameBytes)
        expect(frame.type).toBe(TYPE_DATA)
        expect(frame.esi).toBe(esi)
        expect(frame.k).toBe(info.k)
        expect(frame.totalLen).toBe(info.compressedSize)
        expect(frame.payload.length).toBe(info.mtu)
      }

      // Commit the fixtures.
      const dir = join(FIXTURES_ROOT, fixture.name)
      mkdirSync(dir, { recursive: true })
      writeFileSync(join(dir, 'original.bin'), original)
      writeFileSync(join(dir, 'payload.bin'), payload)
      writeFileSync(join(dir, 'deflate.bin'), payload)
      writeFileSync(join(dir, 'meta.frame'), firstOrThrow(metaFrames))
      writeFileSync(join(dir, 'data.frames'), lengthPrefixed(dataFrames))
      writeFileSync(join(dir, 'repair.frames'), lengthPrefixed(repairs))
      writeFileSync(
        join(dir, 'manifest.json'),
        `${JSON.stringify(
          {
            name: fixture.name,
            originalSize: info.totalSize,
            compressedSize: info.compressedSize,
            compressed: info.compressed,
            k: info.k,
            mtu: info.mtu,
            symbolSize: info.symbolSize,
            sessionId: info.sessionId,
            fileSHA256: info.fileSHA256,
            payloadSHA256: sha256Hex(payload),
            deflateSHA256: sha256Hex(payload),
            profile: { ...info.settings },
            generatedBy: 'pwa-interop-gen',
          },
          null,
          2,
        )}\n`,
      )

      // Then — read the committed bytes back and verify them independently.
      const readData = splitLengthPrefixed(readFileSync(join(dir, 'data.frames')))
      expect(readData.length).toBe(info.k)
      for (const [esi, frameBytes] of readData.entries()) {
        const frame = decodeFrame(frameBytes)
        expect(frame.esi).toBe(esi)
        expect(frame.payload.length).toBe(info.mtu)
      }
      const readRepairs = splitLengthPrefixed(readFileSync(join(dir, 'repair.frames')))
      expect(readRepairs.length).toBe(REPAIR_COUNT)
      for (const frameBytes of readRepairs) {
        expect(decodeFrame(frameBytes).payload.length).toBe(info.mtu)
      }
      const readMeta = parseMetadataFrame(readFileSync(join(dir, 'meta.frame')))
      expect(readMeta.sessionId).toBe(info.sessionId)
      expect(readMeta.k).toBe(info.k)
      expect(readMeta.compressed).toBe(info.compressed)
      const readPayload = readFileSync(join(dir, 'payload.bin'))
      expect(readPayload.length).toBe(info.compressedSize)
      const readManifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as Record<
        string,
        unknown
      >
      expect(readManifest).toMatchObject({
        k: info.k,
        sessionId: info.sessionId,
        payloadSHA256: sha256Hex(readPayload),
      })
    } finally {
      transfer.encoder.dispose()
    }
  })
})

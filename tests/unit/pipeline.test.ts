import { afterEach, describe, expect, it } from 'vitest'
import { compress, decompress } from '../../src/codec/compression/deflate'
import { createRaptorqFountain } from '../../src/codec/fountain/raptorq'
import {
  BYTES_PER_TILE,
  FLAG_COMPRESSED,
  META_MAGIC,
  PROTO_VERSION,
  TYPE_DATA,
  type TransferSettings,
} from '../../src/protocol/constants'
import { parseMetadataFrame } from '../../src/protocol/metadata'
import { sha256Hex } from '../../src/protocol/sha256'
import { decodeFrame } from '../../src/protocol/wire'
import {
  PipelineError,
  prepareTransfer,
  repairFrames,
  transferBytes,
  type PreparedTransfer,
} from '../../src/sender/pipeline'

// Deterministic PRNG (mulberry32) so fixtures and drop sets are reproducible.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a += 0x6d2b79f5
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function randomBytes(length: number, seed: number): Uint8Array<ArrayBuffer> {
  const rand = mulberry32(seed)
  const bytes = new Uint8Array(length)
  for (let i = 0; i < length; i++) bytes[i] = Math.floor(rand() * 256)
  return bytes
}

function repeatedByte(byte: number, length: number): Uint8Array<ArrayBuffer> {
  return new Uint8Array(length).fill(byte)
}

function first<T>(arr: readonly T[]): T {
  const v = arr[0]
  if (v === undefined) throw new Error('expected a non-empty array')
  return v
}

const INPUT = { filename: 'fixture.bin', mime: 'application/octet-stream' } as const
type TransferInput = Parameters<typeof prepareTransfer>[0]

// The pipeline keeps its encoder alive for repair generation; dispose after
// each test so wasm memory does not leak across the suite.
const liveEncoders: Array<{ dispose(): void }> = []
afterEach(() => {
  for (const enc of liveEncoders) enc.dispose()
  liveEncoders.length = 0
})

async function makeTransfer(input: TransferInput): Promise<PreparedTransfer> {
  const transfer = await prepareTransfer(input)
  liveEncoders.push(transfer.encoder)
  return transfer
}

async function decodePayload(transfer: PreparedTransfer): Promise<Uint8Array> {
  const decoder = await createRaptorqFountain().createDecoder(
    transfer.info.compressedSize,
    transfer.info.mtu,
  )
  let out: Uint8Array | undefined
  for (const frameBytes of transfer.dataFrames) {
    out = decoder.decode(decodeFrame(frameBytes).payload)
    if (out !== undefined) break
  }
  if (out === undefined) throw new Error('decoder did not complete from all source frames')
  return out
}

function restoreOriginal(transfer: PreparedTransfer, payload: Uint8Array): Uint8Array {
  return decompress({ data: payload, compressed: transfer.info.compressed })
}

async function rejectionCode(run: () => Promise<unknown>): Promise<string> {
  let thrown: unknown
  try {
    await run()
  } catch (e) {
    thrown = e
  }
  if (!(thrown instanceof PipelineError)) {
    throw new Error(`expected PipelineError, got ${String(thrown)}`)
  }
  return thrown.code
}

describe('prepareTransfer', () => {
  it('round-trips a 64 KiB random binary via default settings (1k)', async () => {
    const input = randomBytes(64 * 1024, 0x51a1e)
    const transfer = await makeTransfer({ file: input, ...INPUT })
    const info = transfer.info
    const expected = compress(input)

    expect(info.settings).toEqual({
      bytesPerTile: '1k',
      layout: 'grid4',
      targetFps: 15,
      highRefresh: false,
    })
    expect(info.settings.bytesPerTile).toBe('1k')
    expect(info.totalSize).toBe(64 * 1024)
    expect(info.filename).toBe(INPUT.filename)
    expect(info.mime).toBe(INPUT.mime)
    expect(info.symbolSize).toBe(BYTES_PER_TILE['1k'].mtu)
    expect(info.mtu).toBe(BYTES_PER_TILE['1k'].mtu)
    // Random data is high-entropy: deflate usually declines to shrink it, but
    // we assert against the actual compress() result, never a hardcoded value.
    expect(info.compressed).toBe(expected.compressed)
    expect(info.compressedSize).toBe(expected.data.length)
    expect(info.k).toBeGreaterThan(0)
    expect(info.k * info.symbolSize).toBeGreaterThanOrEqual(info.compressedSize)
    expect(info.dataFrameCount).toBe(info.k)
    expect(info.metaFrameCount).toBe(1)
    expect(info.totalFrames).toBe(info.k + 1)
    expect(transferBytes(info)).toBe(info.compressedSize)

    const payload = await decodePayload(transfer)
    expect(payload.length).toBe(info.compressedSize)
    const restored = restoreOriginal(transfer, payload)
    expect(restored).toEqual(input)
    expect(info.fileSHA256).toMatch(/^[0-9a-f]{64}$/)
    expect(await sha256Hex(input)).toBe(info.fileSHA256)
  })

  it('compresses a 100 KiB repeated-byte file and restores the ORIGINAL bytes', async () => {
    const input = repeatedByte('a'.charCodeAt(0), 100 * 1024)
    const transfer = await makeTransfer({ file: input, ...INPUT })

    expect(transfer.info.compressed).toBe(true)
    expect(transfer.info.compressedSize).toBeLessThan(transfer.info.totalSize)

    const restored = restoreOriginal(transfer, await decodePayload(transfer))
    expect(restored).toEqual(input)
    expect(await sha256Hex(input)).toBe(transfer.info.fileSHA256)
  })

  it('handles a 1-byte file with k >= 1', async () => {
    const input = new Uint8Array([42])
    const transfer = await makeTransfer({ file: input, ...INPUT })

    expect(transfer.info.totalSize).toBe(1)
    expect(transfer.info.k).toBeGreaterThanOrEqual(1)
    expect(restoreOriginal(transfer, await decodePayload(transfer))).toEqual(input)
  })

  it('rejects an empty file with EMPTY_FILE instead of crashing', async () => {
    expect(await rejectionCode(() => makeTransfer({ file: new Uint8Array(0), ...INPUT }))).toBe(
      'EMPTY_FILE',
    )
  })

  it('round-trips a 2 KiB file with 2k (V34) settings', async () => {
    const input = randomBytes(2 * 1024, 77)
    const transfer = await makeTransfer({
      file: input,
      filename: 'v34.bin',
      mime: 'application/octet-stream',
      settings: { bytesPerTile: '2k', layout: 'row3', targetFps: 24, highRefresh: false },
    })

    expect(transfer.info.settings).toEqual({
      bytesPerTile: '2k',
      layout: 'row3',
      targetFps: 24,
      highRefresh: false,
    })
    expect(transfer.info.mtu).toBe(BYTES_PER_TILE['2k'].mtu)
    expect(transfer.info.symbolSize).toBe(transfer.info.mtu)
    expect(transfer.info.k).toBeGreaterThan(0)
    expect(transfer.info.k * transfer.info.mtu).toBeGreaterThanOrEqual(transfer.info.compressedSize)
    expect(restoreOriginal(transfer, await decodePayload(transfer))).toEqual(input)
  })

  it('round-trips a 2 KiB file with 2.5k (V40) settings', async () => {
    const input = randomBytes(2 * 1024, 99)
    const transfer = await makeTransfer({
      file: input,
      filename: 'v40.bin',
      mime: 'application/octet-stream',
      settings: { bytesPerTile: '2.5k', layout: 'single', targetFps: 15, highRefresh: false },
    })

    expect(transfer.info.settings).toEqual({
      bytesPerTile: '2.5k',
      layout: 'single',
      targetFps: 15,
      highRefresh: false,
    })
    expect(transfer.info.mtu).toBe(BYTES_PER_TILE['2.5k'].mtu)
    expect(transfer.info.symbolSize).toBe(transfer.info.mtu)
    expect(transfer.info.k).toBeGreaterThan(0)
    expect(transfer.info.k * transfer.info.mtu).toBeGreaterThanOrEqual(transfer.info.compressedSize)
    expect(restoreOriginal(transfer, await decodePayload(transfer))).toEqual(input)
  })

  it('rejects settings with an unknown bytesPerTile', async () => {
    const settings = {
      bytesPerTile: '9k',
      layout: 'grid4',
      targetFps: 15,
      highRefresh: false,
    } as unknown as TransferSettings
    await expect(makeTransfer({ file: randomBytes(1024, 1), ...INPUT, settings })).rejects.toThrow(
      TypeError,
    )
  })
})

describe('dataFrames', () => {
  it('every DATA frame validates and carries consistent header fields', async () => {
    const transfer = await makeTransfer({ file: randomBytes(64 * 1024, 0x51a1e), ...INPUT })
    const info = transfer.info
    const expectedFlags = info.compressed ? FLAG_COMPRESSED : 0

    for (const frameBytes of transfer.dataFrames) {
      const frame = decodeFrame(frameBytes)
      expect(frame.type).toBe(TYPE_DATA)
      expect(frame.sessionId).toBe(info.sessionId)
      expect(frame.k).toBe(info.k)
      expect(frame.totalLen).toBe(info.compressedSize)
      expect(frame.flags).toBe(expectedFlags)
      expect(frame.payload.length).toBe(info.symbolSize)
    }

    const esis = transfer.dataFrames.map((fb) => decodeFrame(fb).esi)
    expect(new Set(esis).size).toBe(esis.length)
    for (const esi of esis) expect(esi).toBeLessThan(info.k)
    expect(transfer.dataFrames.length).toBe(info.k)
  })
})

describe('metaFrames', () => {
  it('the META frame parses and matches every info field', async () => {
    const transfer = await makeTransfer({ file: randomBytes(16 * 1024, 5), ...INPUT })
    const info = transfer.info

    expect(transfer.metaFrames).toHaveLength(1)
    const meta = parseMetadataFrame(first(transfer.metaFrames))
    expect(meta).toEqual({
      magic: META_MAGIC,
      protoVer: PROTO_VERSION,
      sessionId: info.sessionId,
      filename: info.filename,
      mime: info.mime,
      totalSize: info.totalSize,
      compressedSize: info.compressed ? info.compressedSize : 0,
      compressed: info.compressed,
      k: info.k,
      symbolSize: info.symbolSize,
      mtu: info.mtu,
      fileSHA256: info.fileSHA256,
      flags: info.compressed ? FLAG_COMPRESSED : 0,
    })

    expect(parseMetadataFrame(first(transfer.metaFrames))).toEqual(meta)
    expect(decodeFrame(first(transfer.dataFrames)).sessionId).toBe(meta.sessionId)
  })
})

describe('loss recovery + repair frames', () => {
  it('reassembles the file after losing 20% of source frames', async () => {
    const input = randomBytes(64 * 1024, 0x51a1e)
    const transfer = await makeTransfer({ file: input, ...INPUT })

    // Drop every 5th source frame (~20%), deterministic by construction.
    const survivors = transfer.dataFrames.filter((_, i) => i % 5 !== 0)
    expect(survivors.length).toBeLessThan(transfer.info.k)

    const decoder = await createRaptorqFountain().createDecoder(
      transfer.info.compressedSize,
      transfer.info.mtu,
    )
    let out: Uint8Array | undefined
    for (const frameBytes of survivors) {
      out = decoder.decode(decodeFrame(frameBytes).payload)
      if (out !== undefined) break
    }
    expect(out).toBeUndefined() // survivors alone cannot complete

    for (const frameBytes of repairFrames(transfer, transfer.info.k)) {
      out = decoder.decode(decodeFrame(frameBytes).payload)
      if (out !== undefined) break
    }
    if (out === undefined) throw new Error('decoder did not complete after repair frames')
    expect(restoreOriginal(transfer, out)).toEqual(input)
  })

  it('repairFrames emits valid DATA frames with distinct esi at or beyond k', async () => {
    const transfer = await makeTransfer({ file: randomBytes(16 * 1024, 5), ...INPUT })
    const info = transfer.info
    const expectedFlags = info.compressed ? FLAG_COMPRESSED : 0

    const repairs = repairFrames(transfer, 5)
    expect(repairs).toHaveLength(5)
    const esis = repairs.map((fb) => decodeFrame(fb).esi)
    expect(new Set(esis).size).toBe(5)
    for (const frameBytes of repairs) {
      const frame = decodeFrame(frameBytes)
      expect(frame.type).toBe(TYPE_DATA)
      expect(frame.sessionId).toBe(info.sessionId)
      expect(frame.k).toBe(info.k)
      expect(frame.totalLen).toBe(info.compressedSize)
      expect(frame.flags).toBe(expectedFlags)
      expect(frame.esi).toBeGreaterThanOrEqual(info.k)
    }
  })
})

describe('fileSHA256', () => {
  it('is stable for the same bytes and differs across files', async () => {
    const file = randomBytes(4 * 1024, 7)
    const other = randomBytes(4 * 1024, 8)

    const a = await makeTransfer({ file, ...INPUT })
    const b = await makeTransfer({ file, ...INPUT })
    expect(a.info.fileSHA256).toBe(b.info.fileSHA256)

    const c = await makeTransfer({ file: other, ...INPUT })
    expect(c.info.fileSHA256).not.toBe(a.info.fileSHA256)
  })
})

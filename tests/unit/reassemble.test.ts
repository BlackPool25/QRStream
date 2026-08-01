import { describe, expect, it } from 'vitest'
import { compress } from '../../src/codec/compression/deflate'
import { createRaptorqFountain } from '../../src/codec/fountain/raptorq'
import { SplitMix32 } from '../../src/codec/fountain/rng'
import { FLAG_COMPRESSED, META_MAGIC, PROTO_VERSION } from '../../src/protocol/constants'
import { buildMetadataFrame, parseMetadataFrame, type Metadata } from '../../src/protocol/metadata'
import { sha256Hex } from '../../src/protocol/sha256'
import { generateSessionId } from '../../src/protocol/wire'
import { Reassembler, ReassemblyError, type ReassemblyResult } from '../../src/receiver/reassemble'

const MTU = 1028
const FIXTURE_FILENAME = 'fixture.bin'
const FIXTURE_MIME = 'application/octet-stream'

interface TransferFixture {
  readonly metadata: Metadata
  readonly sourceSymbols: readonly Uint8Array[]
  readonly repairSymbols: readonly Uint8Array[]
  readonly k: number
}

function randomBytes(length: number, seed: number): Uint8Array<ArrayBuffer> {
  const rng = new SplitMix32(seed)
  const bytes = new Uint8Array(length)
  for (let i = 0; i < length; i++) {
    bytes[i] = rng.int(256)
  }
  return bytes
}

function repeatedByte(byte: number, length: number): Uint8Array<ArrayBuffer> {
  return new Uint8Array(length).fill(byte)
}

function must<T>(value: T | undefined, what: string): T {
  if (value === undefined) {
    throw new Error(`expected ${what}`)
  }
  return value
}

/** Deterministic "drop every `step`-th" survivor set over 0..count-1. */
function survivors(count: number, dropEvery: number): number[] {
  return Array.from({ length: count }, (_, i) => i).filter((i) => i % dropEvery !== 0)
}

/**
 * Compresses the fixture, fountain-encodes it, and derives a validated
 * Metadata document (round-tripped through buildMetadataFrame -> parse) whose
 * totalSize/compressedSize/k/mtu/fileSHA256 all match the real codec output.
 */
async function buildTransfer(
  data: Uint8Array<ArrayBuffer>,
  opts: { readonly mtu?: number; readonly repair?: number } = {},
): Promise<TransferFixture> {
  const mtu = opts.mtu ?? MTU
  const { data: payload, compressed } = compress(data)
  const encoder = await createRaptorqFountain().createEncoder(payload, mtu)
  const k = encoder.sourceSymbolCount
  const source = encoder.encodeSourceSymbols()
  // encodeRepair(count) returns the K source symbols followed by `count`
  // repair symbols; slice the leading K off to keep only the repairs.
  const repair = encoder.encodeRepair(opts.repair ?? k + 16).slice(k)
  const fileSHA256 = await sha256Hex(data)
  const metadata = parseMetadataFrame(
    buildMetadataFrame({
      magic: META_MAGIC,
      protoVer: PROTO_VERSION,
      sessionId: generateSessionId(),
      filename: FIXTURE_FILENAME,
      mime: FIXTURE_MIME,
      totalSize: data.length,
      compressedSize: compressed ? payload.length : 0,
      compressed,
      k,
      symbolSize: encoder.symbolSize,
      mtu,
      fileSHA256,
      flags: compressed ? FLAG_COMPRESSED : 0,
    }),
  )
  encoder.dispose()
  return {
    metadata,
    sourceSymbols: source.map((s) => s.bytes),
    repairSymbols: repair.map((s) => s.bytes),
    k,
  }
}

async function emptyMetadata(): Promise<Metadata> {
  const fileSHA256 = await sha256Hex(new Uint8Array(0))
  return parseMetadataFrame(
    buildMetadataFrame({
      magic: META_MAGIC,
      protoVer: PROTO_VERSION,
      sessionId: generateSessionId(),
      filename: 'empty.bin',
      mime: FIXTURE_MIME,
      totalSize: 0,
      compressedSize: 0,
      compressed: false,
      k: 0,
      symbolSize: 1024,
      mtu: MTU,
      fileSHA256,
      flags: 0,
    }),
  )
}

/** Feeds `kept` via start(), then enough repairs via feedMore() to reach k. */
async function reassembleWithLoss(
  fixture: TransferFixture,
  kept: readonly Uint8Array[],
  keptEsi: readonly number[],
): Promise<ReassemblyResult> {
  const { metadata, repairSymbols, k } = fixture
  const reassembler = new Reassembler({ mtu: metadata.mtu })
  await reassembler.start(metadata, [...kept], new Set(keptEsi))
  expect(reassembler.isComplete).toBe(false)

  const needed = k - kept.length
  reassembler.feedMore([...repairSymbols.slice(0, needed)], new Set())
  expect(reassembler.isComplete).toBe(true)
  return reassembler.finish()
}

describe('Reassembler', () => {
  it('reassembles a 64 KiB compressible file and verifies the SHA-256', async () => {
    const original = repeatedByte('a'.charCodeAt(0), 64 * 1024)
    const { metadata, sourceSymbols } = await buildTransfer(original)
    expect(metadata.compressed).toBe(true)

    const reassembler = new Reassembler({ mtu: metadata.mtu })
    await reassembler.start(metadata, [...sourceSymbols], new Set())
    expect(reassembler.isComplete).toBe(true)
    expect(reassembler.decoded).toBeDefined()

    const result = await reassembler.finish()
    expect(result.verified).toBe(true)
    expect(result.bytes).toEqual(original)
    expect(result.sha256).toBe(metadata.fileSHA256)
    expect(result.mime).toBe(FIXTURE_MIME)
    expect(result.filename).toBe(FIXTURE_FILENAME)
  })

  it.each([10, 20, 30])('reassembles the file after %i%% uniform loss', async (lossPct) => {
    // The pipeline's proven-incompressible fixture seed: 64 KiB random bytes.
    const original = randomBytes(64 * 1024, 0x51a1e)
    expect(compress(original).compressed).toBe(false)
    const fixture = await buildTransfer(original)
    expect(fixture.k).toBeGreaterThan(10)

    const dropEvery = Math.round(100 / lossPct)
    const kept = survivors(fixture.sourceSymbols.length, dropEvery)
    expect(kept.length).toBeLessThan(fixture.k)

    const result = await reassembleWithLoss(
      fixture,
      kept.map((i) => must(fixture.sourceSymbols[i], `symbol ${i}`)),
      kept,
    )
    expect(result.bytes).toEqual(original)
    expect(result.verified).toBe(true)
    expect(result.sha256).toBe(fixture.metadata.fileSHA256)
  })

  it('recovers when joining mid-broadcast (last 40% of source + repair)', async () => {
    const original = randomBytes(64 * 1024, 11)
    const fixture = await buildTransfer(original)
    const tailStart = Math.floor(fixture.k * 0.6)
    const tail = fixture.sourceSymbols.slice(tailStart)
    expect(tail.length).toBeLessThan(fixture.k)

    const { metadata, repairSymbols, k } = fixture
    const reassembler = new Reassembler({ mtu: metadata.mtu })
    await reassembler.start(
      metadata,
      [...tail],
      new Set(Array.from({ length: tail.length }, (_, i) => tailStart + i)),
    )
    reassembler.feedMore([...repairSymbols.slice(0, k - tail.length)], new Set())

    expect(reassembler.isComplete).toBe(true)
    const result = await reassembler.finish()
    expect(result.bytes).toEqual(original)
    expect(result.verified).toBe(true)
  })

  it('handles out-of-order symbols with duplicates', async () => {
    const original = randomBytes(64 * 1024, 13)
    const fixture = await buildTransfer(original)
    const rng = new SplitMix32(99)
    const order = Array.from({ length: fixture.sourceSymbols.length }, (_, i) => i)
    for (let i = order.length - 1; i > 0; i--) {
      const j = rng.int(i + 1)
      const a = order[i]
      const b = order[j]
      if (a === undefined || b === undefined) continue
      order[i] = b
      order[j] = a
    }

    const mixed: Uint8Array[] = []
    for (const idx of order) {
      const symbol = must(fixture.sourceSymbols[idx], `symbol ${idx}`)
      mixed.push(symbol)
      if (idx % 3 === 0) {
        mixed.push(symbol) // duplicate every third symbol
      }
    }

    const reassembler = new Reassembler({ mtu: fixture.metadata.mtu })
    await reassembler.start(fixture.metadata, mixed, new Set())
    expect(reassembler.isComplete).toBe(true)

    const result = await reassembler.finish()
    expect(result.bytes).toEqual(original)
    expect(result.verified).toBe(true)
  })

  it('never verifies a tampered symbol stream (integrity gate)', async () => {
    const original = randomBytes(32 * 1024, 19)
    const fixture = await buildTransfer(original)
    expect(fixture.k).toBeGreaterThan(2)

    const tampered = [...fixture.sourceSymbols]
    const victim = must(tampered[0], 'symbol 0')
    const corrupted = victim.slice()
    corrupted[corrupted.length - 1] = (corrupted[corrupted.length - 1] ?? 0) ^ 0xff
    tampered[0] = corrupted

    const reassembler = new Reassembler({ mtu: fixture.metadata.mtu })
    await reassembler.start(fixture.metadata, tampered, new Set())

    let result: ReassemblyResult | undefined
    let thrown: unknown
    try {
      result = await reassembler.finish()
    } catch (error) {
      thrown = error
    }

    // Whatever the decoder does with a corrupted symbol — produce a wrong
    // file (caught by the hash) or never complete — a tampered stream must
    // never surface as a verified success.
    expect(result).toBeUndefined()
    expect(thrown).toBeInstanceOf(ReassemblyError)
  })

  it('round-trips incompressible data with an uncompressed transfer', async () => {
    const original = randomBytes(16 * 1024, 17)
    expect(compress(original).compressed).toBe(false)
    const { metadata, sourceSymbols } = await buildTransfer(original)
    expect(metadata.compressed).toBe(false)
    expect(metadata.compressedSize).toBe(0)

    const reassembler = new Reassembler({ mtu: metadata.mtu })
    await reassembler.start(metadata, [...sourceSymbols], new Set())
    expect(reassembler.isComplete).toBe(true)

    const result = await reassembler.finish()
    expect(result.bytes).toEqual(original)
    expect(result.verified).toBe(true)
    expect(result.sha256).toBe(metadata.fileSHA256)
  })

  it('reports not-complete when fewer than k distinct symbols arrive', async () => {
    const original = randomBytes(32 * 1024, 23)
    const { metadata, sourceSymbols } = await buildTransfer(original)
    const partial = sourceSymbols.slice(0, Math.floor(metadata.k / 2))

    const reassembler = new Reassembler({ mtu: metadata.mtu })
    await reassembler.start(metadata, [...partial], new Set())

    expect(reassembler.isComplete).toBe(false)
    expect(reassembler.decoded).toBeUndefined()
    await expect(reassembler.finish()).rejects.toMatchObject({
      name: 'ReassemblyError',
      code: 'not-complete',
    })
  })

  it('handles a 0-byte file as an immediately verified empty result', async () => {
    const metadata = await emptyMetadata()
    const reassembler = new Reassembler({ mtu: metadata.mtu })
    await reassembler.start(metadata, [], new Set())

    expect(reassembler.isComplete).toBe(true)
    const result = await reassembler.finish()
    expect(result.bytes).toEqual(new Uint8Array(0))
    expect(result.verified).toBe(true)
  })

  it('reset() clears state and allows a fresh transfer', async () => {
    const original = randomBytes(16 * 1024, 29)
    const fixture = await buildTransfer(original)
    const reassembler = new Reassembler({ mtu: fixture.metadata.mtu })

    await reassembler.start(fixture.metadata, [...fixture.sourceSymbols.slice(0, 1)], new Set())
    expect(reassembler.isComplete).toBe(false)
    reassembler.reset()
    expect(reassembler.isComplete).toBe(false)
    expect(reassembler.decoded).toBeUndefined()

    await reassembler.start(fixture.metadata, [...fixture.sourceSymbols], new Set())
    expect(reassembler.isComplete).toBe(true)
    const result = await reassembler.finish()
    expect(result.bytes).toEqual(original)
  })
})

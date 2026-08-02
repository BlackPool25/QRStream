import { describe, expect, it } from 'vitest'
import { META_MAGIC, TYPE_DATA } from '../../src/protocol/constants'
import { buildMetadataFrame, type Metadata } from '../../src/protocol/metadata'
import { encodeFrame, generateSessionId } from '../../src/protocol/wire'
import { FrameBuffer } from '../../src/receiver/frames'
import {
  computeStats,
  downsampleTarget,
  estimateEta,
  handleFeedResult,
  updateStats,
  type FeedHandleState,
  type ReassemblerLike,
  type ReceiverStats,
  type StatsSample,
} from '../../src/receiver/orchestrate'

const SYMBOL_BYTES = 8

function payloadFor(esi: number): Uint8Array {
  return new Uint8Array([esi])
}

function dataBytes(sessionId: string, esi: number, k: number): Uint8Array {
  return encodeFrame({
    type: TYPE_DATA,
    sessionId,
    esi,
    k,
    totalLen: SYMBOL_BYTES * k,
    flags: 0,
    payload: payloadFor(esi),
  })
}

function metaFor(sessionId: string, k: number): Metadata {
  return {
    magic: META_MAGIC,
    protoVer: 1,
    sessionId,
    filename: 'fixture.bin',
    mime: 'application/octet-stream',
    totalSize: SYMBOL_BYTES * k,
    compressedSize: 0,
    compressed: false,
    k,
    symbolSize: SYMBOL_BYTES,
    mtu: 100,
    fileSHA256: 'ab'.repeat(32),
    flags: 0,
  }
}

function metaBytes(meta: Metadata): Uint8Array {
  return buildMetadataFrame(meta)
}

class FakeReassembler implements ReassemblerLike {
  resetCount = 0
  startCount = 0
  feedMoreCount = 0
  startedSymbols: Uint8Array[] = []
  fedSymbols: Uint8Array[] = []

  reset(): void {
    this.resetCount++
  }

  async start(_metadata: Metadata, symbols: Uint8Array[], _esiSet: Set<number>): Promise<void> {
    this.startCount++
    this.startedSymbols = symbols
  }

  feedMore(symbols: Uint8Array[], _esiSet: Set<number>): void {
    this.feedMoreCount++
    this.fedSymbols = symbols
  }
}

function sample(overrides: Partial<StatsSample>): StatsSample {
  return {
    unique: 0,
    k: undefined,
    totalFramesSeen: 0,
    droppedCount: 0,
    elapsedMs: 0,
    symbolSize: undefined,
    decodedInWindow: 0,
    windowMs: 0,
    ...overrides,
  }
}

const BASE_STATS: ReceiverStats = {
  status: 'idle',
  unique: 0,
  k: undefined,
  totalFramesSeen: 0,
  droppedCount: 0,
  decodeRate: 0,
  bytesPerSecond: 0,
  etaSeconds: undefined,
  progress: 0,
  metaSeen: false,
  fileName: undefined,
  verified: undefined,
}

describe('computeStats (stateless projection)', () => {
  it('reports progress 0 while k is unknown', () => {
    const stats = computeStats(sample({ unique: 42 }))
    expect(stats.progress).toBe(0)
    expect(stats.etaSeconds).toBeUndefined()
  })

  it('clamps progress into [0, 1]', () => {
    expect(computeStats(sample({ unique: 250, k: 100 })).progress).toBe(1)
    expect(computeStats(sample({ unique: 0, k: 100 })).progress).toBe(0)
    expect(computeStats(sample({ unique: 10, k: 0 })).progress).toBe(0)
  })

  it('derives bytesPerSecond and eta from the sample', () => {
    const stats = computeStats(sample({ unique: 40, k: 100, symbolSize: 1024, elapsedMs: 8000 }))
    expect(stats.bytesPerSecond).toBe(5120)
    expect(stats.etaSeconds).toBe(12)
  })

  it('passes droppedCount through unchanged', () => {
    expect(computeStats(sample({ droppedCount: 7 })).droppedCount).toBe(7)
  })

  it('uses the instantaneous window rate as decodeRate', () => {
    expect(computeStats(sample({ decodedInWindow: 10, windowMs: 1000 })).decodeRate).toBe(10)
  })

  it('reports no throughput or ETA before metadata is seen', () => {
    const stats = computeStats(sample({ unique: 10, k: 100 }))
    expect(stats.bytesPerSecond).toBe(0)
    expect(stats.etaSeconds).toBeUndefined()
    expect(stats.metaSeen).toBe(false)
  })
})

describe('updateStats (EMA decode rate)', () => {
  it('smooths decodeRate across known windows', () => {
    let stats = updateStats(BASE_STATS, sample({ decodedInWindow: 5, windowMs: 500 }))
    expect(stats.decodeRate).toBe(5)
    stats = updateStats(stats, sample({ decodedInWindow: 5, windowMs: 500 }))
    expect(stats.decodeRate).toBe(7.5)
    stats = updateStats(stats, sample({ decodedInWindow: 0, windowMs: 500 }))
    expect(stats.decodeRate).toBe(3.75)
  })

  it('carries status, fileName and verified forward from the previous stats', () => {
    const prev: ReceiverStats = {
      ...BASE_STATS,
      status: 'transferring',
      fileName: 'a.bin',
      verified: true,
    }
    const stats = updateStats(prev, sample({ unique: 5, k: 10 }))
    expect(stats.status).toBe('transferring')
    expect(stats.fileName).toBe('a.bin')
    expect(stats.verified).toBe(true)
  })

  it('computes bytesPerSecond from the delta of unique symbols per window, not the lifetime average', () => {
    // 20 new symbols (unique 0 -> 20) in a 1s window at 1024 B/symbol.
    const first = updateStats(
      BASE_STATS,
      sample({ unique: 20, k: 100, symbolSize: 1024, windowMs: 1000 }),
    )
    expect(first.bytesPerSecond).toBe(20480)

    // The next window adds only 5 new symbols in 1s: the rate must fall to
    // 5120, NOT stay at the lifetime average (25 * 1024 / 2 = 12800). A 1s
    // window is a full EMA replacement (alpha = windowMs/1000 = 1).
    const second = updateStats(
      first,
      sample({ unique: 25, k: 100, symbolSize: 1024, windowMs: 1000 }),
    )
    expect(second.bytesPerSecond).toBe(5120)
  })
})

describe('downsampleTarget', () => {
  it('leaves a small capture unchanged', () => {
    expect(downsampleTarget(1280, 720)).toEqual({ width: 1280, height: 720 })
  })

  it('scales a 1080p capture to at most 2MP preserving the aspect ratio', () => {
    const { width, height } = downsampleTarget(1920, 1080)
    expect(width * height).toBeLessThanOrEqual(2_000_000)
    expect(width).toBeLessThanOrEqual(1280)
    expect(Math.abs(width / height - 1920 / 1080)).toBeLessThan(0.005)
  })

  it('scales a 12MP capture down hard', () => {
    const { width, height } = downsampleTarget(4000, 3000)
    expect(width * height).toBeLessThanOrEqual(2_000_000)
    expect(width).toBeLessThanOrEqual(1280)
    expect(width).toBeLessThan(4000)
    expect(Math.abs(width / height - 4 / 3)).toBeLessThan(0.005)
  })
})

describe('estimateEta', () => {
  it('computes remaining bytes divided by the transfer rate', () => {
    expect(estimateEta(40, 100, 5000, 1024)).toBeCloseTo(12.288, 1)
  })

  it('returns undefined when the rate is zero', () => {
    expect(estimateEta(40, 100, 0, 1024)).toBeUndefined()
  })

  it('returns undefined while k or symbolSize is unknown', () => {
    expect(estimateEta(40, undefined, 5000, 1024)).toBeUndefined()
    expect(estimateEta(40, 100, 5000, undefined)).toBeUndefined()
  })

  it('is undefined once unique meets or exceeds k (waiting on the decoder, not more symbols)', () => {
    // The frame buffer counts repair symbols (esi >= k) too, so unique can
    // exceed k while the transfer is still decoding. ETA of 0 would read as
    // "done" — it must be unknowable instead.
    expect(estimateEta(100, 100, 5000, 1024)).toBeUndefined()
    expect(estimateEta(120, 100, 5000, 1024)).toBeUndefined()
  })

  it('clamps the remaining-symbol count to k so repair symbols cannot inflate ETA', () => {
    // unique includes repair symbols; the remaining count must never go below 0.
    expect(estimateEta(99, 100, 5000, 1024)).toBeCloseTo(0.2048, 3)
  })
})

describe('handleFeedResult', () => {
  const freshState = (): FeedHandleState => ({ started: false, fedEsi: new Set() })

  it('resets the reassembler on a new session before metadata arrives', async () => {
    const buffer = new FrameBuffer()
    const fake = new FakeReassembler()
    const session = generateSessionId()

    const result = buffer.feed(dataBytes(session, 0, 10))
    expect(result.isNewSession).toBe(true)

    const outcome = await handleFeedResult(buffer, fake, result, freshState())

    expect(fake.resetCount).toBe(1)
    expect(fake.startCount).toBe(0)
    expect(outcome.action).toBe('reset')
    expect(outcome.state.started).toBe(false)
  })

  it('starts the decoder with all held symbols once metadata is known', async () => {
    const buffer = new FrameBuffer()
    const fake = new FakeReassembler()
    const session = generateSessionId()
    const state = freshState()

    const metaResult = buffer.feed(metaBytes(metaFor(session, 3)))
    const metaOutcome = await handleFeedResult(buffer, fake, metaResult, state)
    expect(metaOutcome.action).toBe('none')
    expect(fake.resetCount).toBe(1)

    const dataResult = buffer.feed(dataBytes(session, 0, 3))
    const dataOutcome = await handleFeedResult(buffer, fake, dataResult, metaOutcome.state)

    expect(fake.startCount).toBe(1)
    expect(fake.startedSymbols).toEqual([payloadFor(0)])
    expect(dataOutcome.action).toBe('start')
    expect(dataOutcome.state.started).toBe(true)
  })

  it('feeds subsequent new symbols via feedMore and skips duplicates', async () => {
    const buffer = new FrameBuffer()
    const fake = new FakeReassembler()
    const session = generateSessionId()
    let state = freshState()

    await handleFeedResult(buffer, fake, buffer.feed(metaBytes(metaFor(session, 3))), state)
    const startOutcome = await handleFeedResult(
      buffer,
      fake,
      buffer.feed(dataBytes(session, 0, 3)),
      state,
    )
    state = startOutcome.state

    const moreOutcome = await handleFeedResult(
      buffer,
      fake,
      buffer.feed(dataBytes(session, 1, 3)),
      state,
    )
    expect(moreOutcome.action).toBe('feed-more')
    expect(fake.feedMoreCount).toBe(1)
    expect(fake.fedSymbols).toEqual([payloadFor(1)])
    state = moreOutcome.state

    const dupOutcome = await handleFeedResult(
      buffer,
      fake,
      buffer.feed(dataBytes(session, 1, 3)),
      state,
    )
    expect(dupOutcome.action).toBe('none')
    expect(fake.feedMoreCount).toBe(1)
  })

  it('does not skip late low-esi symbols (fedEsi tracking)', async () => {
    const buffer = new FrameBuffer()
    const fake = new FakeReassembler()
    const session = generateSessionId()
    let state = freshState()

    await handleFeedResult(buffer, fake, buffer.feed(metaBytes(metaFor(session, 4))), state)
    state = (await handleFeedResult(buffer, fake, buffer.feed(dataBytes(session, 0, 4)), state))
      .state
    state = (await handleFeedResult(buffer, fake, buffer.feed(dataBytes(session, 2, 4)), state))
      .state
    expect(fake.fedSymbols).toEqual([payloadFor(2)])

    const late = await handleFeedResult(buffer, fake, buffer.feed(dataBytes(session, 1, 4)), state)
    expect(late.action).toBe('feed-more')
    expect(fake.fedSymbols).toEqual([payloadFor(1)])
  })

  it('resets feed state when a new session starts mid-stream', async () => {
    const buffer = new FrameBuffer()
    const fake = new FakeReassembler()
    const sessionA = generateSessionId()
    const sessionB = generateSessionId()
    let state = freshState()

    await handleFeedResult(buffer, fake, buffer.feed(metaBytes(metaFor(sessionA, 2))), state)
    state = (await handleFeedResult(buffer, fake, buffer.feed(dataBytes(sessionA, 0, 2)), state))
      .state
    await handleFeedResult(buffer, fake, buffer.feed(dataBytes(sessionA, 1, 2)), state)
    expect(fake.startCount).toBe(1)

    const switchOutcome = await handleFeedResult(
      buffer,
      fake,
      buffer.feed(dataBytes(sessionB, 0, 2)),
      state,
    )
    expect(fake.resetCount).toBe(2)
    expect(switchOutcome.action).toBe('reset')
    expect(switchOutcome.state.started).toBe(false)

    // A symbol for the new session was buffered before its META: restart with it.
    const metaOutcome = await handleFeedResult(
      buffer,
      fake,
      buffer.feed(metaBytes(metaFor(sessionB, 2))),
      switchOutcome.state,
    )
    expect(metaOutcome.action).toBe('start')
    expect(fake.startCount).toBe(2)
    expect(fake.startedSymbols).toEqual([payloadFor(0)])
  })

  it('ignores corrupt frames without touching the reassembler', async () => {
    const buffer = new FrameBuffer()
    const fake = new FakeReassembler()
    const session = generateSessionId()
    const corrupted = dataBytes(session, 0, 10)
    corrupted[30] = 0xff

    const result = buffer.feed(corrupted)
    expect(result.status).toBe('error')

    const outcome = await handleFeedResult(buffer, fake, result, freshState())

    expect(outcome.action).toBe('none')
    expect(fake.resetCount).toBe(0)
    expect(fake.startCount).toBe(0)
    expect(fake.feedMoreCount).toBe(0)
  })
})

import { describe, expect, it } from 'vitest'
import { SplitMix32 } from '../../src/codec/fountain/rng'
import { META_MAGIC, TYPE_DATA } from '../../src/protocol/constants'
import { buildMetadataFrame, type Metadata } from '../../src/protocol/metadata'
import { encodeFrame, generateSessionId, type Frame } from '../../src/protocol/wire'
import { FrameBuffer, type FeedResult } from '../../src/receiver/frames'

const PAYLOAD_LEN = 64

/** Deterministic pseudo-random payload bytes (splitmix32, seeded per esi). */
function payloadFor(esi: number): Uint8Array {
  const rng = new SplitMix32(1000 + esi)
  const bytes = new Uint8Array(PAYLOAD_LEN)
  for (let i = 0; i < PAYLOAD_LEN; i++) {
    bytes[i] = rng.int(256)
  }
  return bytes
}

function dataFrame(sessionId: string, esi: number, k: number): Frame {
  return {
    type: TYPE_DATA,
    sessionId,
    esi,
    k,
    totalLen: k * PAYLOAD_LEN,
    flags: 0,
    payload: payloadFor(esi),
  }
}

function metaFor(sessionId: string, k: number, filename = 'test.bin'): Metadata {
  return {
    magic: META_MAGIC,
    protoVer: 1,
    sessionId,
    filename,
    mime: 'application/octet-stream',
    totalSize: k * PAYLOAD_LEN,
    compressedSize: 0,
    compressed: false,
    k,
    symbolSize: PAYLOAD_LEN,
    mtu: 100,
    fileSHA256: 'ab'.repeat(32),
    flags: 0,
  }
}

/** Deterministic non-identity permutation of esi 0..count-1 (evens, then odds). */
function shuffledEsi(count: number): number[] {
  const order: number[] = []
  for (let i = 0; i < count; i += 2) order.push(i)
  for (let i = 1; i < count; i += 2) order.push(i)
  return order
}

function feedData(buffer: FrameBuffer, sessionId: string, k: number, esi: number): FeedResult {
  return buffer.feed(encodeFrame(dataFrame(sessionId, esi, k)))
}

describe('FrameBuffer', () => {
  it('collects 100 in-order DATA frames with no drops', () => {
    const sessionId = generateSessionId()
    const k = 100
    const buffer = new FrameBuffer()

    for (let esi = 0; esi < k; esi++) {
      expect(feedData(buffer, sessionId, k, esi).status).toBe('ok')
    }

    expect(buffer.uniqueSymbolCount).toBe(100)
    expect(buffer.droppedCount).toBe(0)
    expect(buffer.totalFramesSeen).toBe(100)
    expect(buffer.sessionId).toBe(sessionId)
    expect(buffer.k).toBe(100)
    expect(buffer.symbols()).toHaveLength(100)
    expect(buffer.symbols()[0]).toEqual(payloadFor(0))
    expect(buffer.symbols()[99]).toEqual(payloadFor(99))
    const esiSet = buffer.symbolEsiSet()
    expect(esiSet.has(0)).toBe(true)
    expect(esiSet.has(99)).toBe(true)
  })

  it('collects the same 100 symbols when fed out of order', () => {
    const sessionId = generateSessionId()
    const k = 100
    const buffer = new FrameBuffer()

    for (const esi of shuffledEsi(k)) {
      feedData(buffer, sessionId, k, esi)
    }

    expect(buffer.uniqueSymbolCount).toBe(100)
    expect(buffer.totalFramesSeen).toBe(100)
    expect(buffer.symbols()).toHaveLength(100)
    expect(buffer.symbols()[0]).toEqual(payloadFor(0))
    expect(buffer.symbols()[99]).toEqual(payloadFor(99))
  })

  it('dedups repeated esi without losing frame accounting', () => {
    const sessionId = generateSessionId()
    const k = 100
    const buffer = new FrameBuffer()

    for (let esi = 0; esi < k; esi++) feedData(buffer, sessionId, k, esi)
    for (let i = 0; i < 3; i++) feedData(buffer, sessionId, k, 5)

    expect(buffer.uniqueSymbolCount).toBe(100)
    expect(buffer.totalFramesSeen).toBe(103)
    expect(buffer.droppedCount).toBe(0)
  })

  it('treats a corrupted frame as an error without throwing or mutating state', () => {
    const sessionId = generateSessionId()
    const k = 100
    const buffer = new FrameBuffer()
    for (let esi = 0; esi < 10; esi++) feedData(buffer, sessionId, k, esi)

    const corrupted = encodeFrame(dataFrame(sessionId, 50, k))
    corrupted[30 + 5] = 0xff // flip a payload byte -> BAD_CRC

    const result = buffer.feed(corrupted)
    expect(result.status).toBe('error')
    expect(result.frame).toBeUndefined()
    expect(buffer.droppedCount).toBe(1)
    expect(buffer.uniqueSymbolCount).toBe(10)
    expect(buffer.sessionId).toBe(sessionId)

    // A valid frame after the corrupted one still lands.
    expect(feedData(buffer, sessionId, k, 50).status).toBe('ok')
    expect(buffer.uniqueSymbolCount).toBe(11)
  })

  it('starts fresh on a new session mid-stream', () => {
    const sessionA = generateSessionId()
    const sessionB = generateSessionId()
    const k = 100
    const buffer = new FrameBuffer()

    expect(buffer.feed(buildMetadataFrame(metaFor(sessionA, k))).status).toBe('ok')
    for (let esi = 0; esi < 30; esi++) feedData(buffer, sessionA, k, esi)
    expect(buffer.uniqueSymbolCount).toBe(30)

    const switchResult = feedData(buffer, sessionB, k, 7)
    expect(switchResult.status).toBe('ok')
    expect(switchResult.isNewSession).toBe(true)
    expect(buffer.sessionId).toBe(sessionB)
    expect(buffer.metadata).toBeUndefined()
    expect(buffer.uniqueSymbolCount).toBe(1)
  })

  it('parses META frames and latches the session', () => {
    const sessionId = generateSessionId()
    const k = 100
    const buffer = new FrameBuffer()
    const meta = metaFor(sessionId, k)

    const result = buffer.feed(buildMetadataFrame(meta))

    expect(result.status).toBe('ok')
    expect(result.isNewSession).toBe(true)
    expect(result.meta).toEqual(meta)
    expect(buffer.metadata).toEqual(meta)
    expect(buffer.sessionId).toBe(sessionId)
    expect(buffer.k).toBe(k)
  })

  it('treats a META frame with a new sessionId as a session switch', () => {
    const sessionA = generateSessionId()
    const sessionB = generateSessionId()
    const buffer = new FrameBuffer()
    for (let esi = 0; esi < 10; esi++) feedData(buffer, sessionA, 100, esi)
    const metaB = metaFor(sessionB, 50)

    const result = buffer.feed(buildMetadataFrame(metaB))

    expect(result.isNewSession).toBe(true)
    expect(buffer.sessionId).toBe(sessionB)
    expect(buffer.metadata).toEqual(metaB)
    expect(buffer.uniqueSymbolCount).toBe(0)
    expect(buffer.k).toBe(50)
  })

  it('starts empty', () => {
    const buffer = new FrameBuffer()
    expect(buffer.metadata).toBeUndefined()
    expect(buffer.sessionId).toBeUndefined()
    expect(buffer.k).toBeUndefined()
    expect(buffer.uniqueSymbolCount).toBe(0)
    expect(buffer.totalFramesSeen).toBe(0)
    expect(buffer.droppedCount).toBe(0)
    expect(buffer.symbols()).toEqual([])
    expect(buffer.symbolEsiSet().size).toBe(0)
  })

  it('exposes k from DATA frame headers before any META arrives', () => {
    const buffer = new FrameBuffer()
    const sessionId = generateSessionId()
    feedData(buffer, sessionId, 100, 3)
    expect(buffer.k).toBe(100)
  })

  it('keeps the total bounded with a default repair budget', () => {
    const sessionId = generateSessionId()
    const k = 10
    const buffer = new FrameBuffer()

    for (let esi = 0; esi < 10; esi++) feedData(buffer, sessionId, k, esi) // source
    for (let esi = 10; esi < 35; esi++) feedData(buffer, sessionId, k, esi) // repair

    for (let esi = 0; esi < 10; esi++) {
      expect(buffer.symbolEsiSet().has(esi)).toBe(true)
    }
    expect(buffer.uniqueSymbolCount).toBe(35)
    expect(buffer.uniqueSymbolCount).toBeLessThanOrEqual(k * 1.3 + 1000)
  })

  it('evicts the oldest repair symbols when the repair budget is exceeded', () => {
    const sessionId = generateSessionId()
    const k = 10
    const buffer = new FrameBuffer({ repairBudget: 5 }) // cap at k + 5 = 15 symbols

    for (let esi = 0; esi < 10; esi++) feedData(buffer, sessionId, k, esi)
    for (let esi = 10; esi < 25; esi++) feedData(buffer, sessionId, k, esi)

    const esiSet = buffer.symbolEsiSet()
    for (let esi = 0; esi < 10; esi++) expect(esiSet.has(esi)).toBe(true) // source retained
    for (let esi = 10; esi < 20; esi++) expect(esiSet.has(esi)).toBe(false) // oldest repair evicted
    for (let esi = 20; esi < 25; esi++) expect(esiSet.has(esi)).toBe(true) // newest repair kept
    expect(buffer.uniqueSymbolCount).toBe(15)
  })

  it('reset() clears session state while keeping cumulative counters', () => {
    const sessionId = generateSessionId()
    const buffer = new FrameBuffer()
    feedData(buffer, sessionId, 100, 0)
    feedData(buffer, sessionId, 100, 0)
    buffer.feed(new Uint8Array(8)) // too short to be a frame -> dropped

    buffer.reset()

    expect(buffer.sessionId).toBeUndefined()
    expect(buffer.metadata).toBeUndefined()
    expect(buffer.k).toBeUndefined()
    expect(buffer.uniqueSymbolCount).toBe(0)
    expect(buffer.symbols()).toEqual([])
    expect(buffer.totalFramesSeen).toBe(2)
    expect(buffer.droppedCount).toBe(1)
  })
})

import { describe, expect, it } from 'vitest'
import { crc32c, Crc32c } from '../../src/protocol/crc32c'
import {
  decodeFrame,
  encodeFrame,
  generateSessionId,
  ProtocolError,
  type Frame,
} from '../../src/protocol/wire'
import { buildMetadataFrame, parseMetadataFrame, type Metadata } from '../../src/protocol/metadata'
import { sha256Hex } from '../../src/protocol/sha256'
import {
  BYTES_PER_TILE,
  CRC_LEN,
  FLAG_COMPRESSED,
  HEADER_LEN,
  LAYOUTS,
  MAGIC_QRDF,
  MAX_TOTAL_LEN,
  METADATA_REBROADCAST_EVERY,
  META_MAGIC,
  PROFILE_GRID,
  PROFILE_V40,
  PROTO_VERSION,
  SESSION_ID_LEN,
  TYPE_DATA,
  TYPE_META,
  type BytesPerTileId,
} from '../../src/protocol/constants'

const utf8 = (s: string): Uint8Array<ArrayBuffer> =>
  new Uint8Array(new TextEncoder().encode(s).buffer)

function errCode(fn: () => unknown): string {
  let thrown: unknown
  try {
    fn()
  } catch (e) {
    thrown = e
  }
  expect(thrown).toBeInstanceOf(ProtocolError)
  return (thrown as ProtocolError).code
}

const SID = 'aabbccddeeff0011'

const dataFrame = (payload: Uint8Array, flags = 0): Frame => ({
  type: TYPE_DATA,
  sessionId: SID,
  esi: 3,
  k: 5,
  totalLen: 12_345,
  flags,
  payload,
})

const META: Metadata = {
  magic: META_MAGIC,
  protoVer: 1,
  sessionId: SID,
  filename: 'photo.jpg',
  mime: 'image/jpeg',
  totalSize: 42_000,
  compressedSize: 12_345,
  compressed: true,
  k: 42,
  symbolSize: 1024,
  mtu: 1028,
  fileSHA256: 'ab'.repeat(32),
  flags: FLAG_COMPRESSED,
}

describe('crc32c', () => {
  it('matches RFC 3720 check vector crc32c("123456789")', () => {
    expect(crc32c(utf8('123456789'))).toBe(0xe3069283)
  })

  it('is 0 for empty input', () => {
    expect(crc32c(new Uint8Array(0))).toBe(0x00000000)
  })

  it('matches golden vector for 32 ASCII "a" bytes', () => {
    expect(crc32c(new Uint8Array(32).fill(0x61))).toBe(0xb980f10b)
  })

  it('streaming Crc32c equals one-shot over 10KB random with deterministic splits', () => {
    const data = new Uint8Array(10_240)
    crypto.getRandomValues(data)
    const oneShot = crc32c(data)
    let seed = 12345
    const next = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff)
    const c = new Crc32c()
    let off = 0
    while (off < data.length) {
      const len = 1 + (next() % 500)
      c.update(data.subarray(off, Math.min(off + len, data.length)))
      off += len
    }
    expect(c.finalize()).toBe(oneShot)
  })
})

describe('wire frames', () => {
  it.each([0, 1, 1004, 1024, 1465])(
    'round-trips DATA frame at boundary payload size %d',
    (size) => {
      const frame = dataFrame(new Uint8Array(size).fill(0x5a))
      const encoded = encodeFrame(frame)
      expect(encoded.length).toBe(HEADER_LEN + size + CRC_LEN)
      expect(decodeFrame(encoded)).toEqual(frame)
    },
  )

  it('round-trips totalLen up to MAX_TOTAL_LEN (u24)', () => {
    const frame = { ...dataFrame(new Uint8Array(4)), totalLen: MAX_TOTAL_LEN }
    expect(decodeFrame(encodeFrame(frame)).totalLen).toBe(MAX_TOTAL_LEN)
  })

  it('round-trips META type frames', () => {
    const frame: Frame = { ...dataFrame(utf8('hello')), type: TYPE_META }
    const decoded = decodeFrame(encodeFrame(frame))
    expect(decoded.type).toBe(TYPE_META)
    expect(decoded.payload).toEqual(frame.payload)
  })

  it('round-trips the compressed flag set and unset', () => {
    expect(decodeFrame(encodeFrame(dataFrame(new Uint8Array(10), FLAG_COMPRESSED))).flags).toBe(
      FLAG_COMPRESSED,
    )
    expect(decodeFrame(encodeFrame(dataFrame(new Uint8Array(10), 0))).flags).toBe(0)
  })

  it('rejects a bad magic', () => {
    const encoded = encodeFrame(dataFrame(new Uint8Array(4)))
    encoded[0] = 0x00
    expect(errCode(() => decodeFrame(encoded))).toBe('BAD_MAGIC')
  })

  it('rejects a wrong protocol version', () => {
    const encoded = encodeFrame(dataFrame(new Uint8Array(4)))
    encoded[4] = 2
    expect(errCode(() => decodeFrame(encoded))).toBe('BAD_VERSION')
  })

  it('rejects a CRC mismatch (one payload byte flipped)', () => {
    const encoded = encodeFrame(dataFrame(new Uint8Array(1004).fill(0x11)))
    encoded[HEADER_LEN + 500] = 0xff
    expect(errCode(() => decodeFrame(encoded))).toBe('BAD_CRC')
  })

  it('rejects a truncated frame', () => {
    const encoded = encodeFrame(dataFrame(new Uint8Array(1004)))
    expect(errCode(() => decodeFrame(encoded.subarray(0, encoded.length - 1)))).toBe('TRUNCATED')
    expect(errCode(() => decodeFrame(encoded.subarray(0, HEADER_LEN - 1)))).toBe('TRUNCATED')
  })

  it('rejects trailing bytes after the CRC', () => {
    const encoded = encodeFrame(dataFrame(new Uint8Array(4)))
    const padded = new Uint8Array(encoded.length + 1)
    padded.set(encoded)
    expect(errCode(() => decodeFrame(padded))).toBe('BAD_LENGTH')
  })

  it('rejects reserved flag bits on encode and decode', () => {
    expect(errCode(() => encodeFrame(dataFrame(new Uint8Array(4), 0x02)))).toBe('BAD_FLAGS')
    const encoded = encodeFrame(dataFrame(new Uint8Array(4)))
    encoded[29] = 0x02
    expect(errCode(() => decodeFrame(encoded))).toBe('BAD_FLAGS')
  })

  it('rejects an invalid sessionId hex on encode', () => {
    expect(errCode(() => encodeFrame({ ...dataFrame(new Uint8Array(4)), sessionId: 'zz' }))).toBe(
      'BAD_SESSION_ID',
    )
  })

  it('generateSessionId returns 16 lowercase hex chars, unique per call', () => {
    const a = generateSessionId()
    const b = generateSessionId()
    expect(a).toMatch(/^[0-9a-f]{16}$/)
    expect(b).toMatch(/^[0-9a-f]{16}$/)
    expect(a).not.toBe(b)
  })
})

describe('metadata', () => {
  it('round-trips buildMetadataFrame -> parseMetadataFrame preserving every field', () => {
    expect(parseMetadataFrame(buildMetadataFrame(META))).toEqual(META)
  })

  it('serializes exactly the 13 spec keys as JSON payload', () => {
    const frame = buildMetadataFrame(META)
    const json = JSON.parse(
      new TextDecoder().decode(frame.subarray(HEADER_LEN, frame.length - CRC_LEN)),
    )
    expect(Object.keys(json).sort()).toEqual(
      [
        'magic',
        'protoVer',
        'sessionId',
        'filename',
        'mime',
        'totalSize',
        'compressedSize',
        'compressed',
        'k',
        'symbolSize',
        'mtu',
        'fileSHA256',
        'flags',
      ].sort(),
    )
  })

  it('builds META frames with esi=0 and the payload sessionId in the header', () => {
    const frame = decodeFrame(buildMetadataFrame(META))
    expect(frame.type).toBe(TYPE_META)
    expect(frame.esi).toBe(0)
    expect(frame.sessionId).toBe(SID)
  })

  it('rejects a payload that is not JSON', () => {
    const frame = encodeFrame({ ...dataFrame(utf8('not json')), type: TYPE_META })
    expect(errCode(() => parseMetadataFrame(frame))).toBe('BAD_METADATA_JSON')
  })

  it('rejects a payload sessionId that differs from the header sessionId', () => {
    const payload = utf8(JSON.stringify({ ...META, sessionId: '0000000000000000' }))
    const rebuilt = encodeFrame({
      type: TYPE_META,
      sessionId: 'ffffffffffffffff',
      esi: 0,
      k: META.k,
      totalLen: META.compressedSize,
      flags: 0,
      payload,
    })
    expect(errCode(() => parseMetadataFrame(rebuilt))).toBe('SESSION_ID_MISMATCH')
  })

  it('rejects an inconsistent compressed/compressedSize pair on build', () => {
    expect(() => buildMetadataFrame({ ...META, compressed: true, compressedSize: 0 })).toThrow(
      ProtocolError,
    )
  })

  it('parses metadata with an uncompressed file (compressedSize 0)', () => {
    const plain = { ...META, compressed: false, compressedSize: 0, flags: 0 }
    expect(parseMetadataFrame(buildMetadataFrame(plain))).toEqual(plain)
  })
})

describe('sha256', () => {
  it('matches the known vector sha256("abc")', async () => {
    expect(await sha256Hex(utf8('abc'))).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    )
  })

  it('matches the known vector sha256("")', async () => {
    expect(await sha256Hex(new Uint8Array(0))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    )
  })
})

describe('constants', () => {
  it('pin the wire format constants to the spec', () => {
    expect(MAGIC_QRDF).toEqual([0x51, 0x52, 0x44, 0x46])
    expect(PROTO_VERSION).toBe(1)
    expect(TYPE_DATA).toBe(0x01)
    expect(TYPE_META).toBe(0x02)
    expect(HEADER_LEN).toBe(30)
    expect(CRC_LEN).toBe(4)
    expect(FLAG_COMPRESSED).toBe(0x01)
    expect(METADATA_REBROADCAST_EVERY).toBe(32)
    expect(SESSION_ID_LEN).toBe(8)
    expect(MAX_TOTAL_LEN).toBe(0xffffff)
    expect(PROFILE_GRID).toEqual({
      tiles: [2, 2],
      version: 27,
      ecc: 'L',
      symbolSize: 1024,
      mtu: 1028,
      chunkSize: 1004,
      frameBudget: 1465,
    })
    expect(PROFILE_V40).toEqual({
      tiles: [1, 1],
      version: 40,
      ecc: 'L',
      symbolSize: 2048,
      mtu: 2052,
      chunkSize: 2044,
      frameBudget: 2953,
    })
  })

  it('pins BYTES_PER_TILE to the spec', () => {
    expect(BYTES_PER_TILE).toEqual({
      '1k': { version: 27, symbolSize: 1024, mtu: 1028, chunkSize: 1004, frameBudget: 1465 },
      '2k': { version: 33, symbolSize: 2048, mtu: 2052, chunkSize: 2028, frameBudget: 2140 },
      '2.5k': { version: 40, symbolSize: 2560, mtu: 2564, chunkSize: 2540, frameBudget: 2953 },
    })
  })

  it('pins LAYOUTS to the spec', () => {
    expect(LAYOUTS).toEqual({
      single: { cols: 1, rows: 1 },
      column3: { cols: 1, rows: 3 },
      row3: { cols: 3, rows: 1 },
      grid4: { cols: 2, rows: 2 },
      grid9: { cols: 3, rows: 3 },
    })
  })

  it('every bytes-per-tile profile fits its wire frame within the QR frame budget', () => {
    for (const p of Object.values(BYTES_PER_TILE)) {
      expect(p.mtu).toBe(p.symbolSize + 4)
      expect(HEADER_LEN + p.symbolSize + CRC_LEN).toBeLessThanOrEqual(p.frameBudget)
    }
  })

  const TILE_CAPACITY: Array<readonly [BytesPerTileId, number, number]> = [
    ['1k', 27, 1465],
    ['2k', 33, 2140],
    ['2.5k', 40, 2953],
  ]

  it.each(TILE_CAPACITY)(
    'profile %s uses version %d whose Ecc.LOW capacity %d bounds its wire frame',
    (id, version, capacity) => {
      const p = BYTES_PER_TILE[id]
      expect(p.version).toBe(version)
      expect(p.frameBudget).toBe(capacity)
      expect(HEADER_LEN + p.symbolSize + CRC_LEN).toBeLessThanOrEqual(capacity)
    },
  )
})

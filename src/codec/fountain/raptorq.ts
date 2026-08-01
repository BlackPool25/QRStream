import init, { Decoder, Encoder, EncodingPacket } from 'raptorq/raptorq.js'
import wasmUrl from 'raptorq/raptorq_bg.wasm?url'
import type { EncodedSymbol, FountainDecoder, FountainEncoder, FountainFactory } from './interface'

// The crate derives symbol_size = mtu - (mtu % 8) and its parameter search
// panics ("unreachable") for mtu < 64; max_packet_size is a u16, so 65535 is
// the largest representable value. Guard both so callers get a clean error
// instead of a wasm RuntimeError.
const MIN_MTU = 64
const MAX_MTU = 65535

let initPromise: Promise<void> | undefined

function isNodeRuntime(): boolean {
  return typeof process !== 'undefined' && process.versions?.node !== undefined
}

async function loadWasmBytes(): Promise<Uint8Array> {
  if (isNodeRuntime()) {
    const { readFileSync } = await import('node:fs')
    const { createRequire } = await import('node:module')
    return readFileSync(createRequire(import.meta.url).resolve('raptorq/raptorq_bg.wasm'))
  }
  const response = await fetch(wasmUrl)
  if (!response.ok) {
    throw new Error(`raptorq: failed to load wasm, HTTP ${response.status}`)
  }
  return new Uint8Array(await response.arrayBuffer())
}

// Lazy, module-cached one-time wasm init; a failed init resets so a later call
// can retry.
function ensureWasmInit(): Promise<void> {
  initPromise ??= loadWasmBytes()
    .then(async (bytes) => {
      await init(bytes)
    })
    .catch((error: unknown) => {
      initPromise = undefined
      throw error
    })
  return initPromise
}

function assertValidMtu(mtu: number): void {
  if (!Number.isInteger(mtu) || mtu < MIN_MTU || mtu > MAX_MTU) {
    throw new RangeError(`raptorq: mtu must be an integer in [${MIN_MTU}, ${MAX_MTU}], got ${mtu}`)
  }
}

// esi comes from EncodingPacket.deserialize (the library's own wire parser)
// rather than the array index: it stays correct for any source-block layout or
// packet ordering the encoder may produce, at one cheap wasm alloc per packet.
function readEsi(packet: Uint8Array): number {
  const parsed = EncodingPacket.deserialize(packet)
  const esi = parsed.encoding_symbol_id()
  parsed.free()
  return esi
}

class RaptorqEncoder implements FountainEncoder {
  readonly symbolSize: number
  readonly sourceSymbolCount: number

  private readonly handle: Encoder
  private disposed = false

  constructor(handle: Encoder, sourceSymbolCount: number, symbolSize: number) {
    this.handle = handle
    this.sourceSymbolCount = sourceSymbolCount
    this.symbolSize = symbolSize
  }

  encodeSourceSymbols(): EncodedSymbol[] {
    this.assertUsable()
    return this.toSymbols(this.handle.encode(0))
  }

  encodeRepair(count: number): EncodedSymbol[] {
    this.assertUsable()
    return this.toSymbols(this.handle.encode(count))
  }

  dispose(): void {
    if (!this.disposed) {
      this.disposed = true
      this.handle.free()
    }
  }

  private toSymbols(packets: Uint8Array[]): EncodedSymbol[] {
    return packets.map((packet) => ({ bytes: packet, esi: readEsi(packet) }))
  }

  private assertUsable(): void {
    if (this.disposed) {
      throw new Error('raptorq: encoder used after dispose()')
    }
  }
}

class RaptorqDecoder implements FountainDecoder {
  private readonly handle: Decoder
  private result: Uint8Array | undefined
  private disposed = false

  constructor(handle: Decoder) {
    this.handle = handle
  }

  get isComplete(): boolean {
    return this.result !== undefined
  }

  decode(symbol: Uint8Array): Uint8Array | undefined {
    this.assertUsable()
    if (this.result !== undefined) {
      return this.result
    }
    this.result = this.handle.decode(symbol)
    return this.result
  }

  dispose(): void {
    if (!this.disposed) {
      this.disposed = true
      this.handle.free()
    }
  }

  private assertUsable(): void {
    if (this.disposed) {
      throw new Error('raptorq: decoder used after dispose()')
    }
  }
}

export function createRaptorqFountain(): FountainFactory {
  return {
    async createEncoder(data: Uint8Array, mtu: number): Promise<FountainEncoder> {
      assertValidMtu(mtu)
      if (data.length === 0) {
        throw new RangeError('raptorq: cannot encode an empty file (K would be 0)')
      }
      await ensureWasmInit()
      const handle = Encoder.with_defaults(data, mtu)
      // encode(0) builds the cached encoding plan and yields exactly the K
      // source packets, so K and the wire symbol size fall out immediately.
      const sourcePackets = handle.encode(0)
      return new RaptorqEncoder(handle, sourcePackets.length, sourcePackets[0]?.length ?? mtu)
    },
    async createDecoder(totalLength: number, mtu: number): Promise<FountainDecoder> {
      assertValidMtu(mtu)
      if (totalLength < 1) {
        throw new RangeError('raptorq: cannot decode a zero-length transfer')
      }
      await ensureWasmInit()
      return new RaptorqDecoder(Decoder.with_defaults(BigInt(totalLength), mtu))
    },
  }
}

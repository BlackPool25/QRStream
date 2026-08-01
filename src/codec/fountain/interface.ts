// Byte-oriented fountain codec contract. Implemented by the RaptorQ wrapper
// (and potentially fallback codecs), so every shape here stays DOM-free and
// wire-agnostic: codecs hand out serialized packet bytes that round-trip
// through the protocol's DATA frames untouched.

export interface EncodedSymbol {
  /** Wire-serialized encoding packet (header + payload), ready for a DATA frame. */
  bytes: Uint8Array
  /** Encoding symbol id. Advisory for the caller (e.g. progress "k/unique"); the
   *  decoder itself dedups by esi internally, so duplicate bytes are harmless. */
  esi: number
}

export interface FountainEncoder {
  /** The K source symbols in esi order — the systematic set. */
  encodeSourceSymbols(): EncodedSymbol[]
  /** K source symbols followed by `count` repair symbols (fresh serializations). */
  encodeRepair(count: number): EncodedSymbol[]
  /** Wire byte size of one encoded symbol (== mtu for the supported profiles). */
  readonly symbolSize: number
  /** K = ceil(fileLength / (symbolSize - 4)), for progress and profile selection. */
  readonly sourceSymbolCount: number
  /** Releases the underlying codec resources. No-op after the first call. */
  dispose(): void
}

export interface FountainDecoder {
  /** Feeds one encoded symbol; returns the full file once ≥K distinct symbols
   *  have arrived, undefined until then. Order-independent; duplicates harmless.
   *  After completion, keeps returning the recovered file. */
  decode(symbol: Uint8Array): Uint8Array | undefined
  /** True once decode() has returned the recovered file. */
  readonly isComplete: boolean
  /** Releases the underlying codec resources. No-op after the first call. */
  dispose(): void
}

export interface FountainFactory {
  /** Builds an encoder for one file. mtu must be an integer in [64, 65535]. */
  createEncoder(data: Uint8Array, mtu: number): Promise<FountainEncoder>
  /** Builds a one-shot decoder for one transfer of `totalLength` bytes. */
  createDecoder(totalLength: number, mtu: number): Promise<FountainDecoder>
}

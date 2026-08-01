/**
 * Soak channel models and the encode -> lose -> reassemble driver.
 *
 * The receiver path under test is the real sender pipeline
 * (prepareTransfer/repairFrames) -> a lossy channel -> the real Reassembler.
 * The FrameBuffer (camera scan path) is bypassed here and exercised separately
 * by the FrameBuffer end-to-end test.
 */

import type { EncodedSymbol } from '../../src/codec/fountain/interface'
import { parseMetadataFrame } from '../../src/protocol/metadata'
import { decodeFrame } from '../../src/protocol/wire'
import { Reassembler, type ReassemblyResult } from '../../src/receiver/reassemble'
import { prepareTransfer, repairFrames } from '../../src/sender/pipeline'
import { mulberry32, shuffle } from './soak-fixtures'

export type LossModel =
  | { readonly type: 'drop'; readonly rate: number }
  | { readonly type: 'burst'; readonly count: number }
  | { readonly type: 'shuffle'; readonly window: number }
  | { readonly type: 'duplicate'; readonly rate: number }
  | { readonly type: 'midstream'; readonly dropFraction: number }

export interface SoakOutcome {
  readonly k: number
  readonly fileSHA256: string
  /** Distinct esi the receiver had fed the decoder when it completed. */
  readonly distinctFed: number
  /** Total feed calls, including duplicate payloads the channel repeated. */
  readonly totalFed: number
  readonly overheadRatio: number
  readonly elapsedMs: number
  readonly result: ReassemblyResult | undefined
  readonly thrown: unknown
}

/** A channel model's name for the report table and per-cell seed derivation. */
export function modelName(model: LossModel): string {
  switch (model.type) {
    case 'drop':
      return `drop-${Math.round(model.rate * 100)}%`
    case 'burst':
      return `burst-${model.count}`
    case 'shuffle':
      return `shuffle-${model.window}`
    case 'duplicate':
      return `dup-${Math.round(model.rate * 100)}%`
    case 'midstream':
      return `midstream-${Math.round(model.dropFraction * 100)}%`
  }
}

/**
 * Loss channel. Returns the SUBSET of the transmitted symbol pool the
 * receiver "sees", in receive order.
 *
 * The pool is ordered source-then-repair (the natural broadcast order), so a
 * drop/burst model mimics a receiver scanning a QR stream with frames lost;
 * midstream mimics a receiver that starts scanning partway through a
 * broadcast (its META frame is re-broadcast on the wire, so it still holds
 * the metadata).
 */
export function applyLoss(
  pool: readonly EncodedSymbol[],
  model: LossModel,
  seed: number,
): EncodedSymbol[] {
  switch (model.type) {
    case 'drop': {
      const rand = mulberry32(seed)
      const dropCount = Math.floor(pool.length * model.rate)
      const order = shuffle(
        Array.from({ length: pool.length }, (_, i) => i),
        rand,
      )
      const dropSet = new Set(order.slice(0, dropCount))
      return pool.filter((_, i) => !dropSet.has(i))
    }
    case 'burst': {
      const rand = mulberry32(seed)
      const dropCount = Math.min(model.count, Math.max(1, Math.floor(pool.length * 0.4)))
      const start = Math.floor(rand() * Math.max(1, pool.length - dropCount))
      return pool.filter((_, i) => i < start || i >= start + dropCount)
    }
    case 'shuffle': {
      const rand = mulberry32(seed)
      const out: EncodedSymbol[] = []
      for (let i = 0; i < pool.length; i += model.window) {
        out.push(...shuffle(pool.slice(i, i + model.window), rand))
      }
      return out
    }
    case 'duplicate': {
      const rand = mulberry32(seed)
      const out: EncodedSymbol[] = []
      for (const symbol of pool) {
        out.push(symbol)
        if (rand() < model.rate) out.push(symbol)
      }
      return out
    }
    case 'midstream':
      return pool.slice(Math.floor(pool.length * model.dropFraction))
  }
}

/**
 * Repair symbols the transmitter must emit for a model to still decode:
 * survivors must be >= k + a margin, because the fountain needs slightly more
 * than k distinct symbols with high probability.
 */
export function repairCountFor(model: LossModel, k: number): number {
  const margin = Math.max(16, Math.ceil(k * 0.02))
  switch (model.type) {
    case 'drop':
      return Math.ceil((k * model.rate) / (1 - model.rate)) + margin
    case 'burst':
      return model.count + margin
    case 'midstream':
      return Math.ceil((k * model.dropFraction) / (1 - model.dropFraction) + margin) + margin
    case 'shuffle':
    case 'duplicate':
      return 0
  }
}

/**
 * Runs one full cell of the matrix: prepareTransfer -> repair provisioning ->
 * loss model -> Reassembler fed one symbol at a time until it completes.
 * Returns the outcome without asserting anything so callers control the test.
 */
export async function runTransferCase(input: {
  readonly original: Uint8Array
  readonly filename: string
  readonly mime: string
  readonly model: LossModel
  readonly seed: number
}): Promise<SoakOutcome> {
  const { original, filename, mime, model, seed } = input
  const prepared = await prepareTransfer({ file: original, filename, mime })
  try {
    const metadata = parseMetadataFrame(prepared.metaFrames[0]!)
    const k = metadata.k
    const toSymbols = (frames: readonly Uint8Array[]): EncodedSymbol[] =>
      frames.map((frame) => {
        const decoded = decodeFrame(frame)
        return { bytes: decoded.payload, esi: decoded.esi }
      })
    const source = toSymbols(prepared.dataFrames)
    const repair = toSymbols(repairFrames(prepared, repairCountFor(model, k)))
    const received = applyLoss([...source, ...repair], model, seed)

    const reassembler = new Reassembler({ mtu: metadata.mtu })
    const emptyEsi = new Set<number>()
    await reassembler.start(metadata, [], emptyEsi)
    const t0 = performance.now()
    const distinct = new Set<number>()
    let totalFed = 0
    let result: ReassemblyResult | undefined
    let thrown: unknown
    try {
      for (const symbol of received) {
        totalFed++
        distinct.add(symbol.esi)
        reassembler.feedMore([symbol.bytes], emptyEsi)
        if (reassembler.isComplete) break
      }
      result = await reassembler.finish()
    } catch (error) {
      thrown = error
    } finally {
      reassembler.reset()
    }
    return {
      k,
      fileSHA256: prepared.info.fileSHA256,
      distinctFed: distinct.size,
      totalFed,
      overheadRatio: k === 0 ? 0 : distinct.size / k,
      elapsedMs: performance.now() - t0,
      result,
      thrown,
    }
  } finally {
    prepared.encoder.dispose()
  }
}

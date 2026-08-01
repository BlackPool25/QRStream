/**
 * Soak test suite — the "no data loss with safety" reliability contract.
 *
 * The suite is the driver AND the runner. A standalone scripts/soak.mjs was
 * considered and deliberately SKIPPED as redundant: vitest already transforms
 * the TS src modules, so the soak runs directly under vitest (npm run soak /
 * soak:full), and the loss models, matrix, and report live here.
 *
 * Matrix (size x payload x model):
 *   sizes   1KB, 64KB, 512KB, 1MB always; 10MB when SOAK_FULL=1
 *   payload random (incompressible, S5), text (compressible), zeros (max)
 *   models  drop 10/20/30%, burst-50, shuffle-200, duplicate-10%, midstream-60%
 *
 * Every case: sender pipeline -> lossy channel -> real Reassembler, and must
 * produce byte-identical output with a matching SHA-256 (S1 happy path, S2
 * mid-stream join, S3 loss, S4 tamper never surfaces as verified). The
 * FrameBuffer end-to-end case (camera scan path) lives in
 * soak-integration.test.ts. A report table is written to
 * tests/soak/soak-report.txt on every run.
 */

import { describe, expect, it } from 'vitest'
import { parseMetadataFrame } from '../../src/protocol/metadata'
import { decodeFrame } from '../../src/protocol/wire'
import { Reassembler, ReassemblyError, type ReassemblyResult } from '../../src/receiver/reassemble'
import { prepareTransfer, repairFrames } from '../../src/sender/pipeline'
import { bytesEqual, makePayload, type PayloadKind, type SoakSize } from './soak-fixtures'
import { modelName, runTransferCase, type LossModel } from './soak-helpers'
import { initReport, reportRow } from './soak-report'

const FULL = process.env.SOAK_FULL === '1'

const DEFAULT_SIZES: readonly SoakSize[] = [
  { name: '1KB', bytes: 1 * 1024 },
  { name: '64KB', bytes: 64 * 1024 },
  { name: '512KB', bytes: 512 * 1024 },
  { name: '1MB', bytes: 1024 * 1024 },
]
const FULL_SIZES: readonly SoakSize[] = [{ name: '10MB', bytes: 10 * 1024 * 1024 }]

const PAYLOAD_KINDS: readonly PayloadKind[] = ['random', 'text', 'zeros']

const MODELS: readonly LossModel[] = [
  { type: 'drop', rate: 0.1 },
  { type: 'drop', rate: 0.2 },
  { type: 'drop', rate: 0.3 },
  { type: 'burst', count: 50 },
  { type: 'shuffle', window: 200 },
  { type: 'duplicate', rate: 0.1 },
  { type: 'midstream', dropFraction: 0.6 },
]

const SIZES: readonly SoakSize[] = FULL ? [...DEFAULT_SIZES, ...FULL_SIZES] : DEFAULT_SIZES

const FILE_MIME = 'application/octet-stream'

// Heavy cases get generous budgets: the 10MB mid-stream join feeds ~10k
// symbols through the wasm decoder in full mode.
const CASE_TIMEOUT_MS = FULL ? 300_000 : 60_000

initReport(FULL ? 'full' : 'default')

/** Deterministic per-cell seed so a failing cell reproduces exactly. */
function cellSeed(size: SoakSize, payload: PayloadKind, model: LossModel): number {
  const key = `${size.name}|${payload}|${modelName(model)}`
  let h = 2166136261
  for (let i = 0; i < key.length; i++) {
    h = Math.imul(h ^ key.charCodeAt(i), 16777619)
  }
  return h >>> 0
}

async function runMatrixCell(
  size: SoakSize,
  payload: PayloadKind,
  model: LossModel,
): Promise<void> {
  const seed = cellSeed(size, payload, model)
  const original = makePayload(payload, size.bytes, seed)
  const outcome = await runTransferCase({
    original,
    filename: `${size.name}-${payload}.bin`,
    mime: FILE_MIME,
    model,
    seed,
  })

  const complete = outcome.result !== undefined
  const bytesMatch = outcome.result !== undefined && bytesEqual(outcome.result.bytes, original)
  const hashMatch = outcome.result !== undefined && outcome.result.sha256 === outcome.fileSHA256
  const overheadOk = model.type === 'midstream' || outcome.overheadRatio <= 1.1
  const pass = complete && bytesMatch && hashMatch && overheadOk

  reportRow(
    [
      size.name,
      payload,
      modelName(model),
      pass ? 'PASS' : 'FAIL',
      outcome.overheadRatio.toFixed(3),
      String(outcome.totalFed),
      outcome.elapsedMs.toFixed(0),
    ].join('\t'),
  )

  expect(
    complete,
    outcome.thrown instanceof Error ? String(outcome.thrown) : 'reassembler never completed',
  ).toBe(true)
  if (outcome.result !== undefined) {
    expect(outcome.result.verified).toBe(true)
    expect(bytesEqual(outcome.result.bytes, original)).toBe(true)
    expect(outcome.result.sha256).toBe(outcome.fileSHA256)
  }
  // RaptorQ decodes from ~k distinct symbols; assert the receiver's overhead
  // stays under 10% for the efficiency models. Mid-stream join overhead is a
  // recovery property (its tail must simply hold k symbols), so it is
  // recorded in the report but not bound here.
  if (model.type !== 'midstream') {
    expect(outcome.overheadRatio).toBeLessThanOrEqual(1.1)
  }
}

describe('soak — loss-model matrix (byte-identical reassembly across sizes x payloads x channels)', () => {
  for (const size of SIZES) {
    for (const payload of PAYLOAD_KINDS) {
      for (const model of MODELS) {
        it(
          `recovers ${size.name} ${payload} under ${modelName(model)}`,
          { timeout: CASE_TIMEOUT_MS },
          async () => {
            await runMatrixCell(size, payload, model)
          },
        )
      }
    }
  }
})

describe('soak — integrity gate (S4: tamper never surfaces as verified)', () => {
  it(
    'never verifies a flipped-byte symbol stream at 512KB',
    { timeout: CASE_TIMEOUT_MS },
    async () => {
      const original = makePayload('random', 512 * 1024, 0xdecaf)
      const prepared = await prepareTransfer({
        file: original,
        filename: 'tamper.bin',
        mime: FILE_MIME,
      })
      try {
        const metadata = parseMetadataFrame(prepared.metaFrames[0]!)
        const source = prepared.dataFrames.map((frame) => {
          const decoded = decodeFrame(frame)
          return { bytes: decoded.payload, esi: decoded.esi }
        })
        const tampered = source.map((symbol) => ({ ...symbol }))
        const victim = tampered[0]
        if (victim === undefined) throw new Error('expected at least one source symbol')
        const corrupted = victim.bytes.slice()
        corrupted[Math.floor(corrupted.length / 2)] =
          (corrupted[Math.floor(corrupted.length / 2)] ?? 0) ^ 0x5a
        tampered[0] = { bytes: corrupted, esi: victim.esi }

        // Enough repair to force the decoder to complete on the corrupted set:
        // whatever RaptorQ does with the bad packet, the SHA-256 gate must stop
        // the reassembled bytes from ever surfacing as a verified success.
        const repair = repairFrames(prepared, metadata.k).map((frame) => {
          const decoded = decodeFrame(frame)
          return { bytes: decoded.payload, esi: decoded.esi }
        })

        const reassembler = new Reassembler({ mtu: metadata.mtu })
        await reassembler.start(metadata, [], new Set())
        for (const symbol of [...tampered, ...repair]) {
          reassembler.feedMore([symbol.bytes], new Set())
          if (reassembler.isComplete) break
        }

        let result: ReassemblyResult | undefined
        let thrown: unknown
        try {
          result = await reassembler.finish()
        } catch (error) {
          thrown = error
        } finally {
          reassembler.reset()
        }

        // Never verified=true with wrong bytes: either the gate throws, or the
        // (astronomically unlikely) recovery is byte-correct.
        if (result !== undefined) {
          expect(result.verified).toBe(true)
          expect(bytesEqual(result.bytes, original)).toBe(true)
        } else {
          expect(thrown).toBeInstanceOf(ReassemblyError)
        }
        reportRow(
          [
            '512KB',
            'random',
            'tamper',
            result !== undefined ? 'PASS' : 'GUARDED',
            '-',
            '-',
            '-',
          ].join('\t'),
        )
      } finally {
        prepared.encoder.dispose()
      }
    },
  )
})

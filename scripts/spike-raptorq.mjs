#!/usr/bin/env node
/**
 * Spike validation of raptorq@1.7.24 as the fountain codec for the QR
 * file-transfer PWA.
 *
 * This spike GATES the codec decision (T9). It proves in plain Node:
 *   - encode/decode round-trips 1 MiB of pseudo-random bytes, byte-identical
 *   - transfer_length is a BigInt in the v1.7 wasm API
 *   - wasm initializes from explicit bytes (Node cannot fetch file:// URLs)
 *   - loss resilience: 0% / 10% / 20% uniform packet loss still decodes
 *   - Encoder/Decoder lifecycle: a Decoder is one-shot per file
 *
 * Usage:  node scripts/spike-raptorq.mjs
 *
 * Exit code 0 only if every round-trip is byte-identical AND the 20%-loss
 * decode succeeds at BOTH profile MTUs (1028 and 2052).
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
// NOTE: the package ships `"module": "raptorq.js"` but no `"main"`/`"exports"`,
// so Node cannot resolve the bare specifier `raptorq` (it looks for index.js).
// Import the glue file directly. Under Vite/Vitest the bare specifier resolves
// via the `module` field.
import init, { Encoder, Decoder, EncodingPacket } from 'raptorq/raptorq.js'

const MTUS = [1028, 2052]
const DATA_LEN = 1024 * 1024 // 1 MiB
const LOSSES = [0.1, 0.2]
const BASE_REPAIR_PER_BLOCK = 10

/** Deterministic PRNG (mulberry32) so the fixture and drop sets are reproducible. */
function mulberry32(seed) {
  let a = seed >>> 0
  return function rng() {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function makeData(len, rng) {
  const data = new Uint8Array(len)
  for (let i = 0; i < len; i++) data[i] = (rng() * 256) | 0
  return data
}

function shuffleIndices(n, rng) {
  const idx = Array.from({ length: n }, (_, i) => i)
  for (let i = n - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1))
    const tmp = idx[i]
    idx[i] = idx[j]
    idx[j] = tmp
  }
  return idx
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

/** Resolve a file inside the raptorq package to a filesystem path. */
function resolvePackageFile(specifier) {
  const url = import.meta.resolve(specifier)
  if (url.startsWith('file:')) return fileURLToPath(url)
  return url
}

async function resolveWasm() {
  const pkgJson = JSON.parse(readFileSync(resolvePackageFile('raptorq/package.json'), 'utf8'))
  const wasmPath = resolvePackageFile('raptorq/raptorq_bg.wasm')
  const bytes = readFileSync(wasmPath)
  return { version: pkgJson.version, wasmBytes: bytes, wasmBytesLen: bytes.byteLength }
}

/**
 * Simulate a receiver that scans QR frames one at a time: shuffle the packet
 * order, uniformly drop a fraction, then feed the survivors to a fresh
 * Decoder until it yields the whole file. Returns how many distinct packets
 * the decoder needed (relative to K) plus the decode wall time.
 */
function lossRoundTrip(enc, K, f, rng, dataLen, mtu) {
  // Enough repair symbols so that (1-f) of (K+R) >= K survives the drop.
  const repair = Math.ceil((K * f) / (1 - f)) + 8
  const packets = enc.encode(repair)
  const order = shuffleIndices(packets.length, rng)
  const dropped = new Set(order.slice(0, Math.round(packets.length * f)))
  const dec = Decoder.with_defaults(BigInt(dataLen), mtu)
  let fed = 0
  let out
  const t0 = performance.now()
  for (const i of order) {
    if (dropped.has(i)) continue
    fed++
    out = dec.decode(packets[i])
    if (out !== undefined) break
  }
  const decodeMs = performance.now() - t0
  return { fed, out, repair, decodeMs }
}

async function runMtu(mtu, data, rng) {
  const enc = Encoder.with_defaults(data, mtu)
  const t0 = performance.now()
  const source = enc.encode(0) // systematic: source packets only -> K as the lib reports it
  const planMs = performance.now() - t0
  const K = source.length
  // Measure the serialized packet shape empirically: header bytes + symbol payload.
  const probe = EncodingPacket.deserialize(source[0])
  const symbolSize = probe.data().length
  const headerBytes = source[0].length - symbolSize
  probe.free()

  // Round-trip at 0% loss with a modest repair budget.
  const t1 = performance.now()
  const allPackets = enc.encode(BASE_REPAIR_PER_BLOCK)
  const encodeMs = performance.now() - t1

  const dec = Decoder.with_defaults(BigInt(data.length), mtu)
  const t2 = performance.now()
  let decoded
  for (const p of allPackets) {
    decoded = dec.decode(p)
    if (decoded !== undefined) break
  }
  const decodeMs = performance.now() - t2
  const roundTripOk = decoded !== undefined && bytesEqual(decoded, data)

  const loss = {}
  let loss20Ok = true
  for (const f of LOSSES) {
    const r = lossRoundTrip(enc, K, f, rng, data.length, mtu)
    loss[String(f)] = {
      packetsNeeded: r.fed,
      overhead: r.fed / K,
      decodeMs: r.decodeMs,
      ok: r.out !== undefined && bytesEqual(r.out, data),
    }
    if (f === 0.2 && !loss[String(f)].ok) loss20Ok = false
  }

  return { mtu, K, symbolSize, headerBytes, planMs, encodeMs, decodeMs, roundTripOk, loss20Ok, loss }
}

async function main() {
  const { version, wasmBytes, wasmBytesLen } = await resolveWasm()

  const t0 = performance.now()
  await init(wasmBytes)
  const initMs = performance.now() - t0

  const rng = mulberry32(0x51a1e)
  const data = makeData(DATA_LEN, rng)

  const apiVite = 'import init, { Encoder, Decoder } from "raptorq"'
  const apiNode = 'import init, { Encoder, Decoder } from "raptorq/raptorq.js"'
  const rows = []
  let allOk = true

  for (const mtu of MTUS) {
    const r = await runMtu(mtu, data, rng)
    rows.push(r)
    if (!r.roundTripOk || !r.loss20Ok) allOk = false
  }

  console.log('===========================================================')
  console.log('raptorq spike report')
  console.log('===========================================================')
  console.log(`package version        : ${version}`)
  console.log(`api (Vite/Vitest)      : ${apiVite}`)
  console.log(`api (plain Node)       : ${apiNode}  (no exports/main in pkg)`)
  console.log(`transfer_length        : BigInt`)
  console.log(`wasm size              : ${(wasmBytesLen / 1024).toFixed(1)} KiB (${wasmBytesLen} B)`)
  console.log(`wasm init time         : ${initMs.toFixed(1)} ms`)
  console.log(`payload                : ${(DATA_LEN / 1024).toFixed(0)} KiB pseudo-random`)
  for (const r of rows) {
    console.log('-----------------------------------------------------------')
    console.log(`mtu=${r.mtu}  K(source symbols)=${r.K}  symbolSize=${r.symbolSize} B` +
      `  pktHeader=${r.headerBytes} B  pktLen=${r.symbolSize + r.headerBytes} B  ` +
      `plan(build)=${r.planMs.toFixed(1)} ms`)
    console.log(`  round-trip (0% loss) : ${r.roundTripOk ? 'OK' : 'FAIL'}  ` +
      `encode=${r.encodeMs.toFixed(1)} ms  decode=${r.decodeMs.toFixed(1)} ms`)
    for (const f of LOSSES) {
      const l = r.loss[String(f)]
      console.log(`  loss ${String(f * 100).padStart(2)}% : ${l.ok ? 'OK' : 'FAIL'}  ` +
        `packets needed=${l.packetsNeeded}/${r.K}  overhead=${l.overhead.toFixed(3)}  ` +
        `decode=${l.decodeMs.toFixed(1)} ms`)
    }
  }
  console.log('===========================================================')

  if (allOk) {
    console.log('RESULT: PASS — all round-trips byte-identical, 20%-loss decodes at both MTUs.')
    process.exit(0)
  }
  console.log('RESULT: FAIL — see lines above. Raptorq@1.7.24 cannot gate the codec decision;')
  console.log('        fall back per docs/decisions/raptorq.md.')
  process.exit(1)
}

main().catch((err) => {
  console.error('SPIKE FAILED (uncaught):', err)
  console.error('        raptorq@1.7.24 is not usable in this environment — see docs/decisions/raptorq.md.')
  process.exit(1)
})

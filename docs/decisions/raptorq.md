# ADR: Fountain codec — `raptorq@1.7.24` spike validation

Status: **PASS — adopt (A)** · Date: 2026-08-01 · Gates: `scripts/spike-raptorq.mjs`

## Decision

Adopt **`raptorq@1.7.24`** (wasm-pack build of cberner/raptorq, Apache-2.0) as the
fountain codec for the QR file-transfer PWA. The spike proved encode/decode
round-trips in Node and Vitest, and the package is browser-compatible (single-
threaded wasm, no COOP/COEP needed). Proceed to the codec wrapper task (T9).

## Spike result (summary)

`node scripts/spike-raptorq.mjs` — 1 MiB of deterministic pseudo-random bytes,
both profile MTUs, 0%/10%/20% uniform packet loss:

| MTU | K (source symbols) | symbol size | round-trip | overhead @ 0/10/20% loss |
|---|---|---|---|---|
| 1028 | 1024 | 1024 B | byte-identical | 1.000 / 1.000 / 1.000 |
| 2052 | 512 | 2048 B | byte-identical | 1.000 / 1.000 / 1.000 |

- wasm 234.9 KiB, init ~31–63 ms, encode ~1.3–4.7 ms, decode ~1.4–12 ms (1 MiB).
- **Zero decode overhead confirmed**: the decoder returns the file the moment it
  has received exactly K *distinct* packets — no repair packets needed at 0%
  loss, and only what was lost needs to be replaced at 10%/20% loss
  (overhead ratio = 1.000 in all cases). Systematic property confirmed:
  `encode(0)` returns exactly the K source packets.
- Exit 0 only when every round-trip is byte-identical AND 20%-loss decode
  succeeds at both MTUs.

## API notes (from `node_modules/raptorq/raptorq.d.ts` + glue)

- **Imports** (subpath required, see gotchas):
  `import init, { Encoder, Decoder, EncodingPacket } from 'raptorq/raptorq.js'`
- **`Encoder.with_defaults(data: Uint8Array, mtu: number)`** — static factory.
- **`encoder.encode(repairPerBlock: number): Uint8Array[]`** — returns already-
  **serialized** packets (source symbols first, then repair). `encode(0)` returns
  exactly the K source packets and builds the cached plan; subsequent
  `encode(R)` on the same Encoder reuses it.
- **`Decoder.with_defaults(transfer_length: bigint, mtu: number)`** —
  `transfer_length` is **`BigInt`** (wasm-bindgen i64; passing a Number throws
  `TypeError`). Must equal the encoder's data length; `mtu` must match.
- **`decoder.decode(packet: Uint8Array): Uint8Array | undefined`** — feeds one
  packet; returns the whole decoded file once ≥ K distinct packets have arrived,
  `undefined` until then. Order-independent (RaptorQ property); duplicate
  packets are harmless. (`add()` is an identical sibling in the glue; the spike
  used `decode()`.)
- **`EncodingPacket.deserialize(bytes)`** — gives `source_block_number()`,
  `encoding_symbol_id()`, `data()` for metadata / debugging.
- **Packet wire format**: 4-byte header + symbol payload, total == MTU exactly.
  Symbol size = MTU − 4 (1024 B @ MTU 1028, 2048 B @ MTU 2052),
  K = ceil(fileLen / (MTU − 4)). NOTE: this build uses a **4-byte header**, not
  the 6-byte header of the Rust crate's RFC 6330 `serialize()` — cross-engine
  wire compatibility is NOT guaranteed by this package alone.
- **Encoder/Decoder lifecycle (gotchas)**:
  - A **Decoder is one-shot per file** — `transfer_length` is fixed at
    construction and cannot be reused for another file. Fresh `Decoder` per
    received file. (A received file is one transfer → one Decoder.)
  - The **Encoder must stay alive** (keep a reference, do not call `.free()`)
    while packets are generated; both objects are plain wasm pointer holders
    with explicit `free()` and no auto-finalizer in the glue.
  - Decode cost scales with number of packets: each `decode()` call is one
    JS↔wasm boundary (~µs) plus the Gaussian-elimination solve once K symbols
    are held. For the 10 MB / ~10 k-symbol soak (later task) the boundary
    traffic (~10 k calls) is expected to dominate; must be re-measured there.

## Browser-compat notes (Vite)

- **`"sideEffects": false` confirmed** in the package manifest — safe for
  Vite tree-shaking / PWA bundle.
- **Single-threaded, no SharedArrayBuffer, no worker threads** in the glue —
  **COOP/COEP headers NOT required.** `WebAssembly.Memory` only.
- **Wasm load pattern** (browser): `import wasmUrl from 'raptorq/raptorq_bg.wasm?url'`
  resolves under Vite (dev: `/node_modules/raptorq/raptorq_bg.wasm`, prod:
  content-hashed asset); `fetch(wasmUrl)` → bytes → `init(bytes)`.
  `?init` does **not** work: Vite instantiates with an empty import namespace,
  but the wasm requires the internal `wbg` namespace the glue never exports.
- **Node** cannot `fetch(file://)`, so the spike/probe pass bytes explicitly:
  `await init(readFileSync(wasmPath))`.

## Gotchas found during the spike

1. **Bare `import 'raptorq'` fails in BOTH Node and Vite 8.** The package ships
   only `"module": "raptorq.js"` — no `"exports"`/`"main"`. Node ESM falls back
   to a missing `index.js` (`ERR_MODULE_NOT_FOUND`); Vite 8 refuses with
   *"Failed to resolve entry for package raptorq"*. **Every import (src wrapper,
   tests) must use the subpath `raptorq/raptorq.js`.**
2. **`transfer_length` is BigInt**, not number.
3. **4-byte packet header** (not the crate's 6-byte RFC serialization).
4. **Vitest/Node need `"node"` in tsconfig `types`** for `node:fs` to typecheck
   (TS 6 + `moduleResolution: bundler`; `@types/node` is already present). Added:
   `"types": ["vite/client", "node"]`. Verified net-zero new type errors.

## Testability proof (T9)

`tests/unit/raptorq-spike-probe.test.ts` kept (2 tests): subpath import under
Vitest (node env), explicit-bytes init, tiny round-trip + 20%-loss decode.
Full suite: `npx vitest run` → 8 files / 96 tests / exit 0.

## Fallback ladder

- **(A) `raptorq@1.7.24` ← PRIMARY (adopt).** Validated this spike: Node
  round-trip ✓, 20%-loss ✓, Vitest ✓, `sideEffects:false` ✓, single-threaded ✓,
  Apache-2.0 ✓. Only obstacles were packaging quirks (subpath import; 4-byte
  header), both trivial to work around.
- **(B) `@raptorqr/raptorq-wasm@0.1.1`.** Alternative wasm binding of
  cberner/raptorq. Trigger: if (A)'s missing `exports`/`main` or its non-RFC
  4-byte wire header blocks the browser build or cross-engine interchange.
  NOT spike-validated (would need an install + the same probe).
- **(C) Self-built wasm-pack of `cberner/raptorq v2.0.1`.** Full control (proper
  `exports`, RFC 6330 6-byte serialization, upstream fixes). Cost: Rust toolchain
  + wasm-pack + build CI. Trigger: if both (A) and (B) fail, or if RFC-exact
  wire format is required.

## Recommendation

Proceed with **(A)**. The codec rationale holds: RaptorQ is systematic
(first K packets are source symbols — zero decoding with no loss), zero decode
overhead (overhead ratio 1.000 at every loss level measured), and the only
adaptations T9 needs are: subpath import, per-file one-shot Decoder, BigInt
`transfer_length`, and `?url`-import + `fetch` for the wasm in the browser.
The 10 MB soak task must re-verify decode latency (JS↔wasm per-packet cost).

## Evidence

- Spike: `scripts/spike-raptorq.mjs` (PASS, exit 0)
- Probe: `tests/unit/raptorq-spike-probe.test.ts`
- Package: `node_modules/raptorq/` (README, `raptorq.d.ts`, `raptorq.js`, 240 516 B wasm)

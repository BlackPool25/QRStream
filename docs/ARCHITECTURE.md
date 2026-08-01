# Architecture — QR Data Transfer

An offline PWA that moves a file from one screen to another camera. This document describes
the system as it is implemented (2026-08-01); every name refers to a real symbol in `src/`.

## 1. Data flow

Sender side (left) and receiver side (right), end to end:

```
 SENDER                                            RECEIVER
 ──────                                            ────────
 file (Uint8Array)                                 camera (getUserMedia, 720p/60 ideal)
   │ sha256Hex()  → fileSHA256                        │ rAF loop, dispatch ≤ capture fps
   │ compress()   → deflate L6, best-effort           │ downsampleTarget()  → ≤2MP, ≤1280px
   │ createRaptorqFountain().createEncoder()          │ drawImage → getImageData (RGBA)
   │   K = ceil(len / symbolSize), symbol = mtu−4     │ DecodePool (2–4 workers, round-robin,
   ├─► k DATA frames (esi 0..k−1, source symbols)     │   zero-copy postMessage transfer)
   │   1 META frame (JSON metadata)                   │   decode.worker → zxing-wasm
   │                                                  │     → raw wire-frame bytes
 display loop (SenderDisplay)                         │ FrameBuffer.feed(bytes)
   │ round-robin over k source + repair esis          │   decodeFrame(): magic/CRC-32C/fields
   │ every 32 ticks: 1 tile = META frame              │   dedup by esi; session latch/reset
   │ encodeQrBytes() → V27-L / V40-L matrix           │   META → parseMetadataPayload
   │ renderGrid/renderSingle → RGBA, integer px/module│ handleFeedResult()
   │ putImageData to device-pixel canvas              │ Reassembler.start/feedMore
   │ adaptFps() throttles down on budget overrun      │   RaptorQ decode (any K distinct symbols)
   ▼                                                  │ finish():
 screen (QR grid on display)                          │   inflate if compressed
        ──────────────── camera ────────────────►     │   SHA-256 vs metadata.fileSHA256
                                                      │     (mismatch → ReassemblyError, never saved)
                                                      │ onFile → saveFile() (FSA picker | <a download>)
```

Integrity layering, weakest to strongest: **CRC-32C** per frame (catches corruption of a
single QR), **RaptorQ** (erasure resilience — the file only completes once ≥K distinct
symbols arrived), **SHA-256** whole-file gate (the data-loss detector; the "verified" badge
means exactly this comparison passed). The deflate compression is best-effort: it only
applies when it shrinks the payload (`compressed` flag + frame header bit 0).

## 2. Module map

| Module                             | Responsibility                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Notes                                                                                                                            |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `src/protocol/constants.ts`        | Single source of truth for the wire format: magic, version, frame types, header length, flags, session id length, `MAX_TOTAL_LEN` (16 MiB), metadata re-broadcast cadence, both `Profile`s                                                                                                                                                                                                                                                                                                                                 | Pure constants + the `Profile` interface                                                                                         |
| `src/protocol/wire.ts`             | `encodeFrame`/`decodeFrame` — the 30-byte header + payload + CRC-32C trailer; strict validation with typed `WireErrorCode`s; `generateSessionId` (8 random bytes, `crypto.getRandomValues`)                                                                                                                                                                                                                                                                                                                                | The single source of truth for the frame format; every field validated, CRC mandatory                                            |
| `src/protocol/crc32c.ts`           | Table-driven CRC-32C (Castagnoli, RFC 3720 polynomial), streaming `Crc32c` class + one-shot `crc32c()`                                                                                                                                                                                                                                                                                                                                                                                                                     | Verified against the RFC 3720 check value                                                                                        |
| `src/protocol/sha256.ts`           | `sha256Hex` via WebCrypto (`crypto.subtle.digest`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Node 22+ and browsers                                                                                                            |
| `src/protocol/metadata.ts`         | Metadata JSON document: build/parse with strict field-level validation (`BAD_METADATA_*` codes); `buildMetadataFrame`/`parseMetadataFrame`                                                                                                                                                                                                                                                                                                                                                                                 | Keys: `magic, protoVer, sessionId, filename, mime, totalSize, compressedSize, compressed, k, symbolSize, mtu, fileSHA256, flags` |
| `src/codec/fountain/interface.ts`  | Byte-oriented codec contract: `FountainEncoder`/`FountainDecoder`/`FountainFactory`                                                                                                                                                                                                                                                                                                                                                                                                                                        | DOM-free, wire-agnostic; enables a fallback codec                                                                                |
| `src/codec/fountain/raptorq.ts`    | `raptorq@1.7.24` wasm wrapper: lazy init, `Encoder.with_defaults`/`Decoder.with_defaults`, esi read back via `EncodingPacket.deserialize`, explicit `dispose()`                                                                                                                                                                                                                                                                                                                                                            | Guards mtu ∈ [64, 65535]; one-shot decoder per file; `encode(0)` yields the K source packets                                     |
| `src/codec/fountain/rng.ts`        | Deterministic RNG for tests/spikes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Test-only consumer                                                                                                               |
| `src/codec/compression/deflate.ts` | Best-effort deflate (`pako`, level 6); skips when it would not shrink                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `compressed` flag drives the wire header bit                                                                                     |
| `src/qr/encode.ts`                 | `encodeQrBytes` (byte mode, forced mask 2 for ~10× speed), `fitVersion` (smallest 1..40), `GRID_VERSION`/`GRID_CAPACITY`/`MAX_CAPACITY` constants, `DataTooLongError`                                                                                                                                                                                                                                                                                                                                                      | DOM-free; ECC defaults to LOW                                                                                                    |
| `src/qr/render.ts`                 | `renderGrid` (1–4 tiles into quadrants of an RGBA canvas frame), `renderSingle`, `integerScalePx` (floor, ≥1), `MIN_QUIET_ZONE` = 4                                                                                                                                                                                                                                                                                                                                                                                        | Pure byte output; black fills for null tiles                                                                                     |
| `src/sender/pipeline.ts`           | `prepareTransfer`: file → SHA-256 → deflate → RaptorQ encoder → k DATA frames + 1 META frame + live encoder; `repairFrames`; typed `PipelineErrorCode` (`EMPTY_FILE`, `TOO_LARGE`, `K_SANITY_FAILED`, `FRAME_TOO_LARGE`, `BAD_REPAIR_COUNT`)                                                                                                                                                                                                                                                                               | Pure module (no DOM/File API); profile chosen by caller, default `grid`                                                          |
| `src/sender/pacing.ts`             | fps ceilings (`GRID_MAX_FPS` 24, `V40_MAX_FPS` 12, `MIN_FPS` 8), `computeFrameDelayMs`, `chooseProfile` (grid ≥ 1600 px canvas), `renderBudgetOk` (1.5× margin), `adaptFps` (−4 step, monotonic), `nextEsiRoundRobin` (deterministic), `FramePool` (source frames + lazily cached repair batch: `ceil(k·0.3) + 100`)                                                                                                                                                                                                       | Pure; the "fps discipline" brain                                                                                                 |
| `src/sender/display.ts`            | `SenderDisplay`: rAF loop, canvas sizing (device pixels), tick → esi selection → QR encode → compose → `putImageData`; META tile every 32 ticks; stats every ~500 ms; wake-lock boost; `dispose()` frees the encoder                                                                                                                                                                                                                                                                                                       | The broadcast core; encodes **complete wire frames** (header+payload+CRC), not payloads                                          |
| `src/sender/controls.ts`           | `computePxPerModule` (integer px/module incl. quiet zone), `recommendDistance` (~14 cm per px/module ± 15 cm), wake-lock request/release (best-effort)                                                                                                                                                                                                                                                                                                                                                                     | DOM-guarded                                                                                                                      |
| `src/receiver/camera.ts`           | `acquireCamera` (getUserMedia, `environment` facing, 1280×720 ideal, fps `ideal:60` — never `exact`, so a sub-60 fps camera still starts; `frameRate` omitted when the constraint is unsupported), `readSettings` (read back the **actual** fps), `normalizeGetUserMediaError` → typed `CameraErrorCode`. `focusMode`/`exposureMode` are applied best-effort after acquisition via `advanced` in `tryLockFocusExposure`, not as top-level constraints (an unsupported top-level control constraint rejects the whole call) | iOS reports fps imprecisely; pacing must use `readSettings`                                                                      |
| `src/receiver/decode.ts`           | `prepareDecodeModule` (one-time zxing wasm init; `wasmBinary` for Node, `wasmUrl` for worker), `decodeImageData` (RGBA → `readBarcodes`, formats `['QRCode']`), `RgbaBuffer` normalization                                                                                                                                                                                                                                                                                                                                 | DOM-free enough to run in Node tests                                                                                             |
| `src/receiver/pool.ts`             | `DecodePool`: 2–4 workers (`max(2, min(4, hw−1))`), round-robin dispatch, per-call id correlation, transfer of `data.buffer`, dispose rejects in-flight                                                                                                                                                                                                                                                                                                                                                                    | Worker crash → typed rejection                                                                                                   |
| `src/receiver/frames.ts`           | `FrameBuffer`: session latch (new sessionId → full reset), esi dedup (Map+Set, O(1)), META parse, bounded repair retention (evict oldest repair esi beyond `k + floor(k·0.3) + 1000`), never throws on corrupt input (`dropped`/`error` statuses)                                                                                                                                                                                                                                                                          | Pure, deterministic, Node-testable                                                                                               |
| `src/receiver/reassemble.ts`       | `Reassembler`: one-shot RaptorQ decoder per transfer (mtu from metadata), `start`/`feedMore` (duplicates harmless), `finish()` → inflate → SHA-256 gate → `ReassemblyResult`; typed `ReassemblyErrorCode` (`not-complete`, `hash-mismatch`, `decode-failed`)                                                                                                                                                                                                                                                               | The data-loss detector                                                                                                           |
| `src/receiver/stats.ts`            | Pure stats/derived core: `downsampleTarget` (≤2 MP, ≤1280 px), `estimateEta`, `updateStats`/`computeStats` (EMA decode rate, 1 s time constant), `handleFeedResult` (buffer → reassembler bookkeeping), `EMPTY_STATS`/`EMPTY_FEED_STATE`                                                                                                                                                                                                                                                                                   | Split out to keep every file ≤ 250 LOC                                                                                           |
| `src/receiver/orchestrate.ts`      | `ReceiverOrchestrator`: camera → rAF → downscale → pool → buffer → reassembler → `onFile`; typed lifecycle (`idle/scanning/transferring/complete/error`), serialized `feedQueue`, dispatch limited to actual capture fps, stats every 500 ms, `halt()` stops tracks + pool                                                                                                                                                                                                                                                 | All DOM/worker access lives here; re-exports stats.ts                                                                            |
| `src/receiver/save.ts`             | `saveFile`: File System Access API picker when available, `<a download>` fallback; `sanitizeFilename` (control chars, leading dots, path separators → `_`, 180-char cap), `mimeFromFilename`; typed `SaveErrorCode`                                                                                                                                                                                                                                                                                                        | DOM-guarded for Node safety                                                                                                      |
| `src/ui/*`                         | Preact views: `App` (home/send/receive), `SenderView` (pick → preparing → ready → broadcasting), `SenderBroadcast` (canvas + chips + fullscreen/boost/stop), `ReceiverView` (phases, save flow, error mapping), `StatusOverlay` (status chip, verified/HASH-MISMATCH badge, progress bar, decode/speed/ETA/dropped), `format.ts` (bytes/eta/profile labels), `icons.tsx`                                                                                                                                                   | Signals-based state                                                                                                              |
| `src/workers/decode.worker.ts`     | Per-worker zxing wasm init from the app's own build (`?url`), decodes RGBA, posts `bytes` transferred                                                                                                                                                                                                                                                                                                                                                                                                                      | Offline-friendly: no CDN                                                                                                         |
| `src/wasm-assets.ts`               | Imports both codec wasm `?url` assets so they land in `dist/assets/` and the SW precache                                                                                                                                                                                                                                                                                                                                                                                                                                   | Anti-tree-shake; PWA offline guarantee                                                                                           |

## 3. Wire protocol

Every frame is `Header(30) + Payload(blockLen) + CRC-32C(4)`, all little-endian
(`src/protocol/wire.ts`):

| Offset | Size | Field     | Meaning                                                                                       |
| ------ | ---- | --------- | --------------------------------------------------------------------------------------------- |
| 0      | 4    | magic     | `"QRDF"` (0x51 0x52 0x44 0x46)                                                                |
| 4      | 1    | version   | protocol version (currently 1)                                                                |
| 5      | 1    | type      | `0x01` DATA (RaptorQ symbol bytes), `0x02` META (metadata JSON)                               |
| 6      | 8    | sessionId | 8 random bytes per send session (`crypto.getRandomValues`); exposed as 16 lowercase hex chars |
| 14     | 4    | esi       | RaptorQ encoding symbol id (u32); 0 for META                                                  |
| 18     | 4    | k         | total source symbols for this file (u32)                                                      |
| 22     | 4    | blockLen  | payload length in THIS frame (u32)                                                            |
| 26     | 3    | totalLen  | total file length post-compression (u24, ≤ 16 MiB)                                            |
| 29     | 1    | flags     | bit0 = compressed; bits 1–7 reserved, must be 0                                               |

The CRC-32C trailer covers header + payload; `decodeFrame` recomputes it and rejects any
mismatch with `BAD_CRC`. All other fields are validated (`BAD_MAGIC`, `BAD_VERSION`,
`BAD_TYPE`, `BAD_SESSION_ID`, `BAD_ESI`, `BAD_K`, `BAD_TOTAL_LEN`, `BAD_FLAGS`,
`TRUNCATED`, `BAD_LENGTH`). A frame's payload is the **complete QR content** — the sender
QR-encodes the full wire bytes, and the receiver feeds the decoded bytes straight to
`decodeFrame`.

The META frame payload is a UTF-8 JSON document (keys exactly): `magic` (`"QRDF-META"`),
`protoVer`, `sessionId`, `filename`, `mime`, `totalSize`, `compressedSize` (pinned to 0
when uncompressed), `compressed`, `k`, `symbolSize`, `mtu`, `fileSHA256`, `flags`. Parse
rejects any missing/wrong-typed field, and requires the payload `sessionId` to equal the
frame header's (`SESSION_ID_MISMATCH`).

## 4. Profiles

|                                    | GRID (2×2)         | V40 (single)       |
| ---------------------------------- | ------------------ | ------------------ |
| Tiles                              | 2×2                | 1×1                |
| QR version                         | 27                 | 40                 |
| ECC                                | L                  | L                  |
| Symbol size                        | 1024 B (`mtu − 4`) | 2048 B (`mtu − 4`) |
| MTU                                | 1028 B             | 2052 B             |
| Frame budget (QR capacity @ ECC-L) | 1465 B             | 2953 B             |
| Fps ceiling                        | 24                 | 12                 |
| Canvas requirement                 | ≥ 1600 px square   | any                |

Symbol size = `mtu − 4` because the raptorq wasm build derives `symbol_size = mtu − (mtu % 8)`
and both profile MTUs are ≡ 4 (mod 8). `frameBudget` is the QR byte capacity at that
version/ECC, which is why the pipeline throws `FRAME_TOO_LARGE` if a symbol ever exceeded it.
The grid wins at large canvas sizes (4 tiles in parallel); the V40 profile exists for small
canvases but is **not wired into the UI** (the app always prepares `grid` — a documented
known limitation, see PERF.md §9).

## 5. Key design decisions

**Fountain codes over ACK/retransmission.** The channel is one-way: the sender cannot hear
the receiver, there is no pairing and no start handshake. RaptorQ lets the receiver rebuild
the file from any K distinct symbols (source or repair) in any order, so nothing needs to be
requested, and a receiver that joins mid-broadcast simply collects symbols until it has K.
Verified in the ADR spike (`docs/decisions/raptorq.md`): decode overhead ratio 1.000 at
0/10/20% packet loss.

**ECC-L + fountain over ECC-M.** Per-QR error correction only fixes localized damage inside
one symbol; whole-symbol loss (blur, motion, occlusion) is the fountain's job, and a
receiver that misses a QR just needs another symbol. ECC-L maximizes byte capacity per QR
(V27-L fits 1465 B vs 1058 B frames — a ~1.4× margin; V40-L fits 2953 B vs ~2078 B frames),
so fewer QRs per file at a given fps. CRC-32C per frame + RaptorQ erasure recovery + the
whole-file SHA-256 gate cover what ECC-L does not.

**Metadata re-broadcast every 32 ticks.** A mid-broadcast joiner needs filename, sizes, k,
mtu and the file SHA-256; with no handshake, the only way to learn them is to hear a META
frame. Re-broadcasting every 32 ticks costs 1 tile per 32 frames (grid: 4 data tiles → 3
on META ticks; ~3% throughput) and bounds join latency to ~2.7 s at 12 fps. The e2e
"receiver joining mid-broadcast" spec pins this behavior.

**SessionId reset semantics.** A sessionId identifies one send session (8 random bytes).
`FrameBuffer` latches onto the newest sessionId it sees: any frame carrying a different
sessionId resets all session state (symbols, metadata, k) and the receiver starts over —
that is how a sender restarting a broadcast is recognized without any protocol message.
`totalFramesSeen`/`droppedCount` are cumulative scan-health stats and survive resets.

**The px/module cliff.** Sub-pixel scaling anti-aliases QR modules, which measurably
destroys decode reliability. Therefore: the canvas backing store is sized to device pixels;
each module is rendered at an integer `ppm` (floored, ≥ 1); the grid needs ~1600 px for
~6 px/module at V27 (4 tiles × 125+2·quiet-zone modules in two 800 px quadrants). The
`quietZone` is the QR spec minimum of 4 modules. A screen that cannot deliver ≥ ~2 px/module
for its profile will not decode reliably — this is a physical cliff, not a code path.

**Fps discipline.** The display frame rate must stay **below** the camera's capture rate so
QR refreshes phase-drift across capture frames instead of aliasing (a frame shown for less
than one capture is never seen), and each QR should span ≥ 2 captures. Ceilings: 24 fps for
the grid, 12 for V40; the app targets 15 fps. Because the loop is rAF-driven and
`computeFrameDelayMs(15)` = 67 ms, a 60 Hz display actually delivers **12 fps** (rAF
quantization, measured — PERF.md §6). `adaptFps` steps the rate down by 4 (floored at 8)
when encode+render overruns the frame budget with a 1.5× margin; on this hardware it never
fires (measured work ~13 ms vs 67 ms delay).

**Repair generation and eviction.** The sender's `FramePool` covers esis `k..ceil(k·0.3)+100`
beyond the source set; repair frames are generated lazily in one batch on first use and
cached, so the first repair tick pays a one-time cost and later esis are free. The
receiver's `FrameBuffer` bounds memory at `k + floor(k·0.3) + 1000` distinct symbols and
evicts the **oldest repair esis first** (repair esi grow monotonically over a broadcast, so
the oldest are the least likely to be needed again). This keeps a long-lived broadcast from
growing without bound while keeping a generous repair cushion.

## 6. Async / session lifecycle

**Sender.** `prepareTransfer` is async (wasm init + encode) and yields a `PreparedTransfer`
holding k DATA frames, 1 META frame and a live encoder. `SenderDisplay.start()` begins the
rAF loop; `stop()` cancels it (encoder stays alive); `dispose()` stops and frees the
encoder — called exactly once when the broadcast view unmounts. The loop runs forever with
no start/stop sequencing: "keep showing QRs" is the whole model.

**Receiver.** `ReceiverOrchestrator.start()` acquires the camera (typed `CameraError` on
failure), then runs a rAF loop that dispatches at most one downscaled decode per capture
frame, bounded by in-flight decodes ≤ pool size. Results are serialized through a promise
`feedQueue` into `FrameBuffer` → `handleFeedResult` → `Reassembler`. When the reassembler
completes, `finish()` inflates and SHA-256-verifies; `onFile` fires and the orchestrator
halts (tracks stopped, pool disposed). A new sessionId resets buffer, reassembler and
feed state. Failure paths: `CameraError` (start), `ReassemblyError` (decode/verify —
`hash-mismatch` flips the verified badge to HASH MISMATCH), `SaveError` (save). The status
machine is `idle → scanning → transferring → complete | error`.

## 7. Known limitations (documented, not hidden)

- `chooseProfile` is not wired into the UI; the app always broadcasts the 2×2 grid
  (PERF.md §9.1). On small canvases this means fewer px/module.
- 15 fps target renders at a measured 12 fps on 60 Hz displays (rAF quantization, PERF.md §6).
- No encryption — by design (THREAT-MODEL.md).

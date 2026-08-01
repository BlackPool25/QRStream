# THREAT-MODEL.md — QR Data Transfer (offline QR file-transfer PWA)

Status: **PASS WITH ACCEPTED RISKS** · Date: 2026-08-01 · Wave 6 T21

## Verdict

No exploitable vulnerability requiring a code change was found. The SHA-256
integrity gate is airtight (verified across three test suites), the parsing
layer rejects every malformed input shape with no unchecked indexing or integer
overflow path, and the app makes **zero network calls** — the only data export
is the QR broadcast on the sender's screen.

Two **Low-severity resource-exhaustion hardening recommendations** are
documented (attacker-controlled `k` in the receiver buffer; attacker-controlled
`totalSize` on the uncompressed decoder path). Both are accepted risk under the
stated threat model — they require a physically-present attacker with screen
access and sustained camera exposure — and are listed with exact fixes for a
future wave. One Info-level hardening note (missing CSP) is recorded.

### Scope

- Target: whole `src/` tree of the QR file-transfer PWA (protocol, codec,
  sender, receiver, ui, workers, PWA/service-worker config).
- Base/diff: full-tree review of working tree at HEAD (`d6d4b41`); no code
  modified by this review.
- Commands run:
  - `rg` for `fetch|XMLHttpRequest|WebSocket|sendBeacon|EventSource` in `src/`
    → 2 hits, both same-origin wasm asset loads (see §h).
  - `rg` for `eval|new Function|dangerouslySetInnerHTML|innerHTML|document.write|window.open|SharedArrayBuffer|localStorage|indexedDB` in `src/` → clean (one comment only).
  - `npm audit` (prod + dev, network) → `found 0 vulnerabilities`.
  - Empirical probe: `Decoder.with_defaults(4GiB-1, 1028)` via
    `node_modules/raptorq/raptorq.js` → constructs in ~21 ms, no allocation
    bomb (see §e).
  - Test evidence: `tests/unit/reassemble.test.ts`, `tests/soak/soak.test.ts`,
    `tests/e2e/transfer.spec.ts`, `tests/e2e/pwa-offline.spec.ts`,
    `tests/unit/{frames,protocol,save}.test.ts` (all cited below).

### Findings summary

| Severity          | Title                                                              | CWE      | Status                            |
| ----------------- | ------------------------------------------------------------------ | -------- | --------------------------------- |
| High (inherent)   | Broadcast interception / shoulder-surfing                          | CWE-200  | ACCEPTED (user decision)          |
| Medium (residual) | Untrusted broadcaster controls filename/mime claims                | CWE-345  | ACCEPTED (broadcast, no pairing)  |
| Low               | Receiver buffer unbounded retention when attacker sets `k` = 2³²−1 | CWE-400  | ACCEPTED (see §e fix)             |
| Low               | Uncompressed decoder created with attacker `totalSize` up to 4 GiB | CWE-400  | ACCEPTED (empirically bounded)    |
| Info              | No CSP header                                                      | CWE-693  | ACCEPTED (hardening note)         |
| —                 | CRC32C is integrity-only (not authentication)                      | CWE-347  | RESOLVED by design + SHA-256 gate |
| —                 | Filename/metadata sanitization                                     | CWE-22   | RESOLVED                          |
| —                 | Wire/JSON parsing safety, u24 bounds                               | CWE-190  | RESOLVED                          |
| —                 | XSS / UI injection                                                 | CWE-79   | RESOLVED                          |
| —                 | Service worker scope / staleness                                   | CWE-353  | RESOLVED                          |
| —                 | Camera privacy / exfiltration                                      | CWE-359  | RESOLVED                          |
| —                 | Supply chain / wasm safety                                         | CWE-1357 | RESOLVED                          |

---

## a. Broadcast interception / shoulder-surfing — ACCEPTED (core design)

**Finding (severity: High — inherent, not a defect):** Anyone with a camera
can point it at the sender's screen, capture the QR stream, and reassemble the
file. RaptorQ is _systematic_: the first `k` packets are the source symbols
(src/codec/fountain/interface.ts contract; ADR docs/decisions/raptorq.md:117–119
"first K packets are source symbols — zero decoding with no loss"), so a
capturing device needs no special state to decode — the first k distinct frames
it sees decode into the payload, then CRC32C + the receiver pipeline apply
exactly as for the intended receiver. The wire frame carries the complete
transfer (header + payload + CRC32C, src/sender/display.ts:7–10) and the
receiver path that reassembles an intercepted stream is the same one the app
uses (src/receiver/orchestrate.ts:176–195).

**Evidence:**

- "No encryption: this is a pure broadcast with no pairing" —
  src/sender/pipeline.ts:13.
- Product copy states the design explicitly: "No pairing, no network, nothing
  leaves the room." — src/ui/App.tsx:55–58; "No network — the receiver scans
  your screen." — src/ui/SenderView.tsx:96–98.
- The display loop broadcasts **forever** with no start/end sequencing, and
  re-broadcasts the META frame every 32 ticks so _any_ camera joining
  mid-stream latches the session — src/sender/display.ts:4–5, 184–189;
  src/protocol/constants.ts:28.
- `sessionId` is 8 random bytes (src/protocol/wire.ts:192–195) used purely for
  dedup/session latching (src/receiver/frames.ts:85–89) — it is a stream
  identifier, **not** a key, and offers zero confidentiality.

**Status: ACCEPTED.** Explicit user decision: pure broadcast, no pairing, no
encryption. The sender's screen is the only exposure surface, and the app's
privacy claim is scoped to that: "nothing leaves the room." Mitigation is
physical, not technical: same-room, same-display, control who can see the
screen (fullscreen + brightness-boost UI exist to make the intended receiver's
job easier — src/ui/SenderBroadcast.tsx:76–96, src/sender/controls.ts:17–26 —
not to hide the stream). No partial mitigation is possible without violating
the no-pairing decision (any scheme that binds a receiver requires a shared
secret or channel). Documented, not treated as a bug.

---

## b. Integrity — RESOLVED (CRC + SHA-256 gate); residual metadata trust ACCEPTED

### b.1 CRC32C is a checksum, not authentication — RESOLVED by design

**Finding (Info):** The per-frame CRC32C (src/protocol/crc32c.ts:23–25,
recomputed and enforced at src/protocol/wire.ts:175–178) is a plain keyless
checksum. Any party that can capture or inject a frame can recompute it —
forging a CRC-valid frame is a few lines of code. It is an _erasure/corruption_
guard (rejects transmission noise and sloppy injection), not an authenticity
bound.

**Status: RESOLVED** — not by design intent alone: the real integrity gate is
the whole-file SHA-256 (§b.2), and the two layers together are what the threat
model relies on. The protocol documentation says exactly this
(src/protocol/wire.ts:16–18; src/receiver/reassemble.ts:9–11).

### b.2 The SHA-256 gate — RESOLVED (verified airtight)

**Finding (severity: High if broken; verified not broken):** The final check is
`finish()` in src/receiver/reassemble.ts:142–169: the RaptorQ-decoded payload
is (optionally) inflated, hashed with WebCrypto SHA-256
(src/protocol/sha256.ts:13–21), and compared against `metadata.fileSHA256`
(which itself must match `/^[0-9a-f]{64}$/`, src/protocol/metadata.ts:71).
Any mismatch throws `ReassemblyError('hash-mismatch')` (reassemble.ts:162–167).

**Airtightness argument — every path that could return a result:**

1. `finish()` **throws** `not-complete` when the decoder never produced output
   (reassemble.ts:148–150) and `decode-failed` when the wasm decoder errored or
   inflate failed (145–147, 152–157).
2. The **only** `verified: true` in the codebase is reassemble.ts:168, which is
   unreachable except after the hash comparison at 162 has passed with an
   exact match. (Verified by grep: `verified: true` appears in exactly two
   places — reassemble.ts:168 and orchestrate.ts:216, the latter reached only
   after `await this.reassembler.finish()` resolves, orchestrate.ts:211–218.)
3. A tampered stream therefore either fails to decode (never completes), or
   decodes to wrong bytes whose hash ≠ `fileSHA256` → throws. It can never
   surface `verified=true` with wrong bytes.
4. The UI's "VERIFIED (SHA-256)" badge is driven by `verified === true`
   (src/ui/StatusOverlay.tsx:153–157); on a hash mismatch the orchestrator
   flips `verified` to `false` and renders "HASH MISMATCH"
   (orchestrate.ts:250–251, StatusOverlay.tsx:158–162).

**Test evidence (three independent suites):**

- `tests/unit/reassemble.test.ts:223–250` — _"never verifies a tampered symbol
  stream (integrity gate)"_: one symbol flipped → `result` must be undefined
  and a `ReassemblyError` thrown.
- `tests/soak/soak.test.ts:140–208` — _"S4: tamper never surfaces as
  verified"_: 512 KB random payload, one byte flipped mid-file, fed with
  enough repair to force decoder completion → either the gate throws
  (GUARDED) or the recovered bytes are byte-equal (PASS); never
  `verified=true` with wrong bytes.
- `tests/e2e/transfer.spec.ts:85–108` — the verified badge "only renders on a
  matching hash" (line 85); saved bytes asserted byte-identical to the fixture
  **and** an independent SHA-256 of the saved bytes equals the fixture hash
  (lines 102–108).

### b.3 Residual: the broadcaster's claims are trusted — ACCEPTED

**Finding (severity: Medium, residual):** The hash binds the received bytes to
what the _broadcaster claimed_. It does not bind the broadcaster's identity or
intent. A malicious screen can broadcast a valid file (consistent
`fileSHA256`, decodes fine) that is simply not what the receiver thinks it is
— and can claim **any** filename/MIME in the META frame
(src/protocol/metadata.ts:106–120; those values flow untouched into the
save path: src/receiver/reassemble.ts:168 → src/ui/ReceiverView.tsx:113 →
src/receiver/save.ts:140). "Valid" here means self-consistent, not
trusted-origin.

**Status: ACCEPTED.** Inherent to broadcast with no pairing: authenticity of
the _sender_ is deliberately out of scope (user decision — see §a). The
receiver's guarantee is scoped to _transmission integrity_ (what you scanned
is exactly what the screen claimed, byte-for-byte, proven by SHA-256), not
_source authenticity_. This matches the app's own UI language ("✓ Verified —
file complete" is a transfer-integrity badge, src/ui/ReceiverView.tsx:209–211).
Any remediation (authenticating the broadcaster) requires pairing/identity,
which the design rejects.

---

## c. Malicious metadata / filename injection — RESOLVED (residuals documented)

**Finding:** `filename` and `mime` arrive from the broadcast
(metadata.ts:106–120; only type-checked as strings). The save path sanitizes
before touching the filesystem/UI.

**`sanitizeFilename` — src/receiver/save.ts:70–82, applied at save.ts:140:**

1. Strips all C0/C1/DEL control characters (line 73) — kills `\u0000`, CR/LF,
   ESC, etc.
2. Strips _leading_ dots before separator replacement (line 76) so
   traversal-shaped `..\evil.txt` becomes `_evil.txt`, not `.._evil.txt`
   (comment lines 74–75).
3. Replaces `\` and `/` with `_` (line 77) — no path separators survive.
4. Empty result → `FALLBACK_NAME` `'file'` (lines 78–80); never throws.
5. Caps at 180 chars preserving the extension (lines 81, 84–96).

**Test evidence:** `tests/unit/save.test.ts:8–37` — `a/b/c.txt`→`a_b_c.txt`,
`..\evil.txt`→`_evil.txt`, `..evil`→`evil`, `.hidden`→`hidden`, `....`→`file`,
control chars stripped, 180-char cap keeps `.txt` and prefix bytes.

**Where the name lands:**

- FSA save: `showSaveFilePicker` `suggestedName` (save.ts:163–171) — the user
  confirms/renames in a native picker.
- Fallback `<a download>`: `anchor.download = name` (save.ts:186) — the name
  only ever goes into the `download` attribute, never into `href`
  (href is a `Blob` URL, save.ts:183–185). Browsers additionally sanitize the
  download attribute themselves.
- UI: displayed as an escaped text node / `title` attribute
  (src/ui/StatusOverlay.tsx:177–181) — see §f.

**Residual risks (accepted, documented):**

- _Windows reserved names_ (`CON`, `NUL`, `AUX`, `COM1–9`, `LPT1–9`) and
  _trailing dots/spaces_ are **not** stripped. These are only meaningful on
  Windows; the FSA picker is user-confirmed there and the download attribute is
  browser-sanitized. Target platforms are phones/desktop browsers; noted as a
  hardening option, not a defect. (Save the receiver's _own_ device: on
  Windows, the picker prevents a bad write; on the download path the browser
  sanitizes.)
- _MIME_: `metadata.mime` is a free-form string (metadata.ts:111) used for the
  Blob type and picker accept hint (save.ts:169, 182). `mimeFromFilename`
  (save.ts:124–131) is a best-effort map with
  `application/octet-stream` fallback — currently used only by tests, not the
  app's save path. A hostile MIME cannot execute inside the app (Blob types are
  inert; see §f); worst case it types the saved file differently when the user
  later opens it on their own device — the same "downloading a file from an
  untrusted screen" reality as §b.3, accepted.

---

## d. Payload parsing safety — RESOLVED

**Wire frame (`decodeFrame`, src/protocol/wire.ts:140–189)** — every field
validated before use:

- Minimum length `HEADER_LEN + CRC_LEN` → `TRUNCATED` (141–143).
- Magic `"QRDF"` (146–150), protocol version (151–153), frame type ∈ {DATA,
  META} (154–157), reserved flag bits must be 0 (158–161).
- `blockLen` (u32 from header) must match the physical frame length exactly —
  shorter → `TRUNCATED` (163–170), longer → `BAD_LENGTH` (171–173). No
  allocation is driven by a declared `blockLen`: the payload is sliced from the
  actual received bytes after the exact-length check (187).
- CRC32C recomputed over header+payload and compared (175–178).

**u24 `totalLen` overflow path:** `totalLen` is read from three header bytes
(wire.ts:185) so it is ≤ 0xFFFFFF **by construction** — there is no arithmetic
that can overflow. Encode asserts `totalLen ≤ MAX_TOTAL_LEN`
(wire.ts:101–103; `MAX_TOTAL_LEN = 0xffffff`, src/protocol/constants.ts:34).
Test: `tests/unit/protocol.test.ts:111–113` round-trips `totalLen =
MAX_TOTAL_LEN`; wire constants pinned at `protocol.test.ts:265–275`.

**No unchecked array indexing:** all reads are guarded `DataView` gets or
length-checked comparisons; the only table lookup is the CRC table with a
`& 0xff` mask (src/protocol/crc32c.ts:40).

**Metadata (`parseMetadataFrame`, src/protocol/metadata.ts:140–155 + 61–81):**
frame type must be META (142–147); JSON payload must parse to an object
(90–100); every field type-checked (38–54); `sessionId` regex-validated
(70), `fileSHA256` 64-hex validated (71), `totalSize ≤ u32`, `compressedSize ≤
MAX_TOTAL_LEN` (16 MiB), `k/symbolSize/mtu ≤ u32`, `flags ≤ FLAG_COMPRESSED`
(72–77), `compressed` consistent with `compressedSize` (78–80); payload
`sessionId` must equal the frame-header `sessionId` (149–154). Test evidence:
protocol.test.ts:219–243 (non-JSON → `BAD_METADATA_JSON`; sessionId mismatch →
`SESSION_ID_MISMATCH`; inconsistent compressed pair rejected).

**Reassembler feed bounds:** `totalLength = compressed ? compressedSize :
totalSize` (reassemble.ts:81) — `compressedSize` is capped at 16 MiB by
validation (metadata.ts:73); decoder creation failures are wrapped
(90–97); only actually-held symbols are ever fed to the wasm decoder
(105–125), and the RaptorQ crate is itself bounds-checked (its own
parameter search; wrapper guards MTU ∈ [64, 65535], src/codec/fountain/
raptorq.ts:9–10, 45–49).

---

## e. Denial of service / resource exhaustion — RESOLVED with 2 accepted Low findings

**RESOLVED (bounded by design):**

- **No pre-allocation by `k`:** `FrameBuffer` stores only actually-received
  distinct `(sessionId, esi)` payloads in a `Map` + `Set`
  (src/receiver/frames.ts:53–54, 162–167). Attacker-claimed `k` never drives
  an allocation.
- **Eviction bounds repair retention:** budget = `floor(k * 0.3) + 1000`,
  `maxSymbols = k + budget`, oldest repair (esi ≥ k) evicted first; source
  symbols are never evicted (frames.ts:168–184). Tests:
  `tests/unit/frames.test.ts:204–217` (bounded at ≤ k·1.3 + 1000) and
  219–232 (oldest-repair eviction).
- **Decode worker cap:** `poolSize() ≤ 4` (src/receiver/pool.ts:24–27),
  `DECODE_POOL_SIZE = 4` (src/ui/ReceiverView.tsx:16), in-flight decodes gated
  at the pool limit (src/receiver/orchestrate.ts:133–135), decode results
  serialized through one queue (164–167).
- **QR decode is per-frame CPU:** camera frames are downsampled to ≤ 2 MP /
  ≤ 1280 px wide (src/receiver/stats.ts:14–15, 49–71); each decode is one
  bounded worker task.
- **Wire size cap:** `compressedSize ≤ MAX_TOTAL_LEN` (16 MiB) enforced on
  encode (src/sender/pipeline.ts:126–131) and validated on parse
  (metadata.ts:73).
- **Session reset:** any new `sessionId` (a garbage/cycling broadcaster
  included) resets buffer state (frames.ts:85–89, 186–192) and the reassembler
  (src/receiver/stats.ts:193–196).

**Low finding 1 — attacker `k` = 2³²−1 disables eviction (ACCEPTED):**
`k` is attacker-controlled from any DATA header (frames.ts:92–93) and
`validateMetadata` permits `k ≤ 0xFFFFFFFF` (metadata.ts:74). With `k` huge,
`maxSymbols ≈ 5.6 × 10⁹` never triggers, so a malicious screen streaming
_distinct_ esi grows the buffer without eviction. Growth is rate-bounded by QR
decode throughput (~tens of frames/s × ≤ ~2 KB) ≈ tens of KB/s; reaching
100 MB requires ~1 h of continuous scanning of a hostile screen. Attacker
requirements: physical screen the receiver points its camera at, sustained
exposure; the user can end it by leaving the view (tracks stop,
orchestrate.ts:256–265). **Status: ACCEPTED** under the "malicious screen"
trust model (§b.3). **Fix (recommended, do not apply in this review):** cap
`k` at a sane bound (e.g. reject/replace frames with `k > 2²⁰`) or cap
`maxSymbols` at an absolute value (e.g. `k + min(budget, 2000)`) in
`FrameBuffer.storeSymbol` (frames.ts:168–169) and/or bound `metadata.k` in
`validateMetadata`.

**Low finding 2 — attacker `totalSize` up to 4 GiB on the uncompressed
decoder path (ACCEPTED):** for `compressed: false`, `totalLength =
metadata.totalSize` (reassemble.ts:81), which may be up to 0xFFFFFFFF
(metadata.ts:72) — a META frame can claim a 4 GiB transfer. Empirically
verified against the shipped wasm: `Decoder.with_defaults(4 GiB−1, 1028)`
constructs in ~21 ms and returns `undefined` on decode (lazy, no allocation
bomb — probe run during this review). Impact: a decoder that can never
complete at QR rates (a legitimate 4 GiB transfer would need ~2M symbols × 1 KB
each), plus per-packet incremental decode work that grows with received
symbols — a slow, self-limiting CPU cost, bounded by QR input rate and
cleared by any new session. **Status: ACCEPTED** (same attacker model as
finding 1; measured bound, no crash, no verified-success path). **Fix
(recommended):** bound `totalSize` in `validateMetadata` (metadata.ts:72) to
`MAX_TOTAL_LEN`-consistent values, or clamp `totalLength` in
`Reassembler.start` (reassemble.ts:81) to the 16 MiB wire limit.

---

## f. XSS / UI injection — RESOLVED

**Finding:** `filename` (and `mime`) from the broadcast are rendered in the UI
and used in the save path — a classic injection sink if unescaped.

**Evidence of safety:**

- **No raw-HTML sink exists:** grep across `src/` for
  `dangerouslySetInnerHTML | innerHTML | document.write | eval( | new Function`
  → zero hits. No `innerHTML` anywhere in the Preact tree.
- **Preact escapes by default:** filename is rendered as a JSX text node and
  `title` attribute — both auto-escaped (src/ui/StatusOverlay.tsx:177–181;
  src/ui/SenderBroadcast.tsx:110–112). Same for the save-confirmation text
  (src/ui/ReceiverView.tsx:238–244).
- **`<a download>` fallback:** `href` is always a `Blob` URL
  (save.ts:183–185); the filename goes only into the `download` attribute
  (186); URL revoked in `finally` (193). A Blob URL cannot carry
  `javascript:`/`data:` content — no script execution vector.
- **No `javascript:` URLs, no `window.open` with attacker data** (grep clean).
- CSS class interpolation uses only internal enum values
  (StatusOverlay.tsx:152), never attacker data.

**Residual:** none inside the app. The _saved file itself_ may be executed
later by the user's own OS/browser (e.g. an HTML/SVG payload from a hostile
broadcaster) — that is the §b.3/§c "untrusted broadcaster" reality, outside
the app's trust boundary, accepted.

---

## g. Service worker scope / update flow — RESOLVED

**Config (src/vite.config.ts:9–57):**

- `generateSW` with `registerType: 'autoUpdate'` (line 13) and `injectRegister:
'auto'` (16) — the generated SW `skipWaiting()` + `clientsClaim()`s and
  takes over on reload (comment lines 11–12); no custom SW code, no
  `navigator.serviceWorker` in app code.
- `scope: '/'` (line 29) — SW scope is the app origin root.
- **Precache only, no runtime caching:** `globPatterns` covers
  `js/css/html/wasm/png/svg` (49); `maximumFileSizeToCacheInBytes` 4 MiB (51,
  needed for the 1.02 MiB zxing wasm — src/wasm-assets.ts:18); `navigateFallback:
'/index.html'` (54); **no `runtimeCaching` at all** (55–56). Nothing
  cross-origin is ever cached; every fetchable asset is same-origin and
  precached.
- Both wasm files are forced into the build graph (`?url` imports,
  src/wasm-assets.ts:14–15; anti-tree-shake `void wasmAssets`, src/main.tsx:8)
  so the precache manifest includes them — proven by e2e:
  `tests/e2e/pwa-offline.spec.ts:20` ("service worker precaches both wasm
  modules and serves the app offline").

**Stale-wasm / update flow:** built assets are content-hashed
(`dist/assets/<hash>` — wasm-assets.ts:5–7), so a SW can only serve one
_consistent_ version (old manifest = old hashes); there is no mixed
old/new state. With `autoUpdate`, a new build's SW activates on the next load
and the new manifest takes over; while offline, the previous version persists
until an online load — acceptable for a stateless app (no local state worth
protecting, vite.config.ts:10–11). The only stale-version window is the
brief skipWaiting/claim cycle, which is standard PWA behavior.

**Info hardening note (ACCEPTED):** `index.html` ships **no CSP** header/meta
(index.html:1–13). The app is fully static with no inline scripts other than
the module entry, so a strict CSP is low-friction; note wasm instantiation
needs `'wasm-unsafe-eval'` if CSP is added. Not a vulnerability today
(no injection sink, §f), recorded as hardening.

---

## h. Camera privacy / data exfiltration — RESOLVED

**Finding:** the receiver holds a live camera stream — the natural concern is
what leaves the device.

**Evidence of safety:**

- `getUserMedia` requests **video only**, rear `facingMode: 'environment'`
  (src/receiver/camera.ts:58–69, 84); single prompt per origin; errors
  normalized to typed `CameraError`s (89–91, 144–166).
- Frames are processed **in memory only**: `drawImage` → `getImageData`
  (src/receiver/orchestrate.ts:151–152) → RGBA transferred to a decode worker
  via `postMessage` (src/receiver/pool.ts:70; src/workers/decode.worker.ts:27–29)
  → decoded bytes into the `FrameBuffer`. Nothing is written to disk, storage,
  or any remote.
- **No network calls exist** — offline proof by grep over `src/`:
  - `fetch` appears exactly twice: a comment in wasm-assets.ts:10 and
    `raptorq.ts:24` — `fetch(wasmUrl)` where `wasmUrl` is the **same-origin,
    precached, content-hashed build asset** (src/codec/fountain/raptorq.ts:1–3,
    24–29; ADR docs/decisions/raptorq.md:73–79).
  - zxing wasm loads via `locateFile` overriding to the bundled local `?url`
    asset (src/workers/decode.worker.ts:7, 16; src/receiver/decode.ts:66–71).
  - No `XMLHttpRequest`, `WebSocket`, `EventSource`, `sendBeacon`, no
    third-party URLs, no `import()` of remote code (the only dynamic imports
    are Node-gated `node:fs`/`node:module`, raptorq.ts:19–22, unreachable in
    the browser). No `localStorage`/`indexedDB`.
- Tracks are stopped on halt and on leaving the view
  (orchestrate.ts:256–265; src/ui/ReceiverView.tsx:50–54).

**Status: RESOLVED.** The **only** data export in the entire app is the QR
broadcast on the sender's screen (§a) — which is the feature. Camera frames
never leave the device in any form.

---

## i. Dependencies / supply chain — RESOLVED (residuals documented)

**Runtime deps** (src/../package.json:20–27, locked by package-lock.json):
`preact 10.29.7`, `@preact/signals 2.10.1`, `pako 3.0.1`, `raptorq 1.7.24`,
`zxing-wasm 3.1.2`, `@ribpay/qr-code-generator 1.0.6`. Dev-only: vite/vitest/
playwright/eslint/prettier/typescript/jsqr/pngjs — not shipped (`private: true`,
package.json:47).

- **`npm audit` (prod and dev, run 2026-08-01): `found 0 vulnerabilities`.**
- **No high-risk patterns:** no `eval`/`new Function` in src or in the
  bundled dependency code paths exercised; no dynamic import of remote URLs;
  no `child_process`/fs access in the browser bundle.
- **`raptorq`** is a wasm-pack build of cberner/raptorq (Apache-2.0), 240 516 B
  wasm — ADR docs/decisions/raptorq.md:7, 128. Subpath-only import
  (`raptorq/raptorq.js`) required — packaging quirk, not a risk (ADR:83–87).
- **`zxing-wasm`** default `locateFile` points at a CDN, but the app **always**
  overrides it with the local precached asset (decode.worker.ts:16); the
  bare-default branch (decode.ts:73) is unreachable from the app.
- **`pako` 3.0.1** pure-JS deflate; **`@ribpay/qr-code-generator`** (Nayuki
  port) pure-JS QR encoder; **preact/signals** — mainstream, widely deployed.

**Residual (accepted):** the two wasm binaries are third-party compiled
artifacts; trust rests on the npm registry + lockfile integrity, content-hash
pinning at build time, and the 0-vuln audit. No vendored source re-review or
SBOM was performed in this wave. Severity: Info.

---

## j. WASM safety — RESOLVED

**Finding:** `raptorq` and `zxing-wasm` are the only native code; wasm is a
trust boundary of its own.

**Evidence:**

- **raptorq:** single-threaded, **no SharedArrayBuffer**, no worker threads in
  the glue; `WebAssembly.Memory` only — **COOP/COEP headers not required**
  (ADR docs/decisions/raptorq.md:71–72). Browsed-verified wrapper adds MTU
  guards (src/codec/fountain/raptorq.ts:9–10, 45–49) so the crate's parameter
  search cannot be panicked via the API surface.
- **zxing:** single-threaded reader running inside dedicated workers
  (src/receiver/pool.ts:90–93; decode.worker.ts:16–21).
- Grep for `SharedArrayBuffer` in `src/` → zero usage (only a comment in
  src/protocol/sha256.ts:9).
- Both modules are pure data codecs (pixels/symbols in → bytes out): they
  import no host functions beyond linear memory and are fully sandboxed by the
  browser; worker threads additionally isolate zxing from the main thread.

**Status: RESOLVED.** No COOP/COEP needed (documented in the ADR); no
cross-origin isolation requirement; no `SharedArrayBuffer` anywhere.

---

## Downgraded or rejected candidates

| Candidate                                                            | Reason                                                                                                                                                            |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "Attacker can forge frames (CRC32C is keyless)" as a standalone vuln | Correct fact, wrong framing: CRC is explicitly the erasure guard; the SHA-256 whole-file gate is the authenticity-of-bytes check and is verified airtight (§b.2). |
| "META frame with `k=2³²−1` causes a huge allocation"                 | Falsified by code: buffer stores only seen esi, never allocates by `k` (frames.ts:162–167). Remaining effect is slow retention growth → Low finding 1.            |
| "Decoder with 4 GiB `totalSize` crashes/hangs the receiver"          | Falsified empirically: `with_defaults(4 GiB−1, 1028)` ~21 ms, decode returns `undefined`; no crash, no huge allocation (§e Low finding 2).                        |
| "Filename `..\evil.txt` escapes the save directory"                  | Falsified: leading dots stripped before separator replacement; test-pinned `save.test.ts:12` (`..\evil.txt` → `_evil.txt`).                                       |
| "XSS via filename in StatusOverlay"                                  | Falsified: no `innerHTML`/`dangerouslySetInnerHTML` in the tree; Preact escapes text + attributes (§f).                                                           |
| "SW caches cross-origin content"                                     | Falsified: precache-only with no `runtimeCaching`; glob limited to same-origin asset types (vite.config.ts:43–56).                                                |
| "CDN wasm exfiltration"                                              | Falsified: both wasm loads are overridden to same-origin precached assets; CDN default branch unreachable in-app.                                                 |

## Residual risk (not tested / limits)

- **Physical-layer realism** (camera decode rates in hostile lighting, distance,
  screen glare) is a reliability concern, not a security one; soak/e2e use a
  virtual camera (tests/e2e/helpers/virtual-camera.ts).
- **Third-party wasm internals** were not source-audited; behavior verified by
  black-box probes and the crate's own tests (ADR), not by Rust code review.
- **No fuzzing** of `decodeFrame`/`parseMetadataPayload` was run this wave;
  validation is exhaustive-by-inspection (§d) and unit-tested for the malformed
  shapes the team enumerated.
- **CSP** and the two Low-severity hardening items (§e) are documented, not
  implemented — left to code-owning waves.
- Local cryptographic post-quantum / side-channel concerns are out of scope
  (WebCrypto SHA-256, no secrets involved).

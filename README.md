# QR Data Transfer

Offline-first PWA that moves files from one device's screen into another device's camera —
a continuous stream of QR codes, no network, no pairing, no server. The sender broadcasts a
file as a cycling 2×2 grid of QR codes (plus a single-large-QR profile); the receiver scans
the screen with its camera, decodes the stream live, reassembles the file with a RaptorQ
fountain codec, verifies its SHA-256 against the sender's metadata, and saves it. Everything
happens on device: bytes never leave the room.

- **Zero network** — the transfer path never touches a socket; both devices can be in airplane mode after first load.
- **No pairing, no handshake** — the receiver just points its camera at the sender's screen and starts collecting. A receiver can join mid-broadcast.
- **No data loss** — every frame is CRC-32C-checked and the reassembled file is SHA-256-verified against the metadata; a mismatch is surfaced, never silently saved.
- **No encryption** — deliberate design decision (broadcast channel, no pairing; see [THREAT-MODEL.md](docs/THREAT-MODEL.md)).

## Honest throughput expectations

This is a QR code stream — it is slow, on purpose. The numbers below are measured, not
promised ([docs/PERF.md](docs/PERF.md), 2026-08-01, Playwright headless Chromium via a
virtual camera):

| File                 | Wall time (e2e) | Effective rate |
| -------------------- | --------------- | -------------- |
| 1 MiB random         | ~23 s           | ~46 KB/s       |
| 512 KiB random       | ~12 s           | ~44 KB/s       |
| 256 KiB compressible | ~4.7 s          | ~56 KB/s       |
| 64 KiB random        | ~3.3 s          | ~20 KB/s       |

Rates are dominated by the broadcast cadence, not decode cost: the 2×2 grid runs at a
measured **12 fps** (the 15 fps target quantizes to 12 on a 60 Hz display) × 4 tiles ≈
48 symbols/s ≈ **~48 KB/s raw**, minus compression and repair overhead. The receiver's
decode budget has ~27× headroom. Small files look slower because fixed startup dominates.
The wire format caps a single transfer at **16 MiB** (`totalLen` is 24 bits); the soak
matrix validates up to 10 MB with a loss model (overhead ratio 1.000).

For practical use: **files up to a few MB transfer in under a couple of minutes; anything
larger is a test of patience.** A 10 MB file at ~46 KB/s is roughly 3.5 minutes of steady
screen time.

## Quick start

```bash
npm install        # install
npm run dev        # dev server (localhost — camera + PWA features work on secure context)
npm run build      # typecheck + production build (dist/)
npm run preview    # serve the production build locally
```

The camera, File System Access API, wake lock and service worker all require a **secure
context** (HTTPS or `localhost`). For testing on a real phone, serve the build over HTTPS
(e.g. `vite preview --host` behind a tunnel, or deploy to any static host — the app works
fully offline after the first load).

## How to use

**Send** (one device, e.g. a phone):

1. Open the app, tap **SEND**, pick or drag a file.
2. Wait for preparation (compress + fountain-encode — a status card shows size, profile and symbol count).
3. Tap **Begin broadcast**. Hold the device screen toward the other device's camera.
4. Use **Fullscreen** (helps the camera) and **Boost** (wake lock keeps the screen on; raise brightness manually). The broadcast loops forever with no start/stop sequencing — the receiver can join at any point.

**Receive** (another device, or the same phone's second camera view):

1. Tap **RECEIVE**, allow camera access.
2. Point the camera at the sender's screen, steady, ~15–30 cm away (the overlay shows a distance hint on the sender).
3. Live stats (unique/k symbols, decode fps, speed, ETA, dropped frames) appear in the status overlay.
4. When the file completes, the overlay shows **✓ VERIFIED (SHA-256)**; tap **Save file** (native picker where available, download fallback otherwise).

Both devices stay offline. No QR codes need to be read by humans; nothing is typed or paired.

## Platform support

| Surface                           | Support                                                                                                                                                                             |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Chrome / Edge (desktop + Android) | Full — primary target; all features (camera, FSA picker, wake lock, PWA)                                                                                                            |
| Safari / iOS                      | Works — camera scanning via zxing-wasm; requires HTTPS + user gesture for camera; FSA picker absent → `<a download>` fallback                                                       |
| Firefox                           | Works — camera + download fallback; wake lock behind flags on some versions                                                                                                         |
| Any modern browser                | Needs `getUserMedia` + WebAssembly (zxing + raptorq). No iOS 14-era quirks are accommodated; iOS **must** be ≥ 15.4 (or the era where `getUserMedia` + wasm are reliable on iPhone) |

Camera requirements: a rear camera that can resolve the QR grid from a phone-to-phone
distance. The sender renders the grid at ≥ 4–6 px/module on a large canvas (V27 grid,
1600 px canvas ≈ 6 px/module); small-screen senders fall back to fewer px/module — see
[DEVICE-MATRIX.md](docs/DEVICE-MATRIX.md) for the measured device matrix and
[PERF.md §9](docs/PERF.md) for the known profile-selection limitation on small canvases.
The receiver requests 720p/60 fps (ideal — it starts on any camera) and downscales captures to ≤ 2 MP (1280 px wide) before decoding.

## Design decisions (short version)

- **Broadcast, not pairing** — one-way data flow; the receiver needs no handshake (see [ADR](docs/decisions/raptorq.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **No encryption** — deliberate; the threat model is an open broadcast channel.
- **RaptorQ fountain codec** — any K of K+repair symbols rebuild the file; no retransmission channel exists.
- **ECC-L on the QRs** — per-QR correction handles localized damage; erasures (missed frames) are the fountain's job, so capacity-maximizing ECC-L wins.
- **px/module physics** — modules are rendered at integer pixel scales on a device-pixel canvas so they stay crisp in the camera's view; sub-pixel anti-aliasing is a decode killer.

## Project structure

```
src/
  protocol/    wire format (header + CRC-32C), metadata JSON, SHA-256, constants
  codec/       RaptorQ fountain wrapper (wasm), deflate compression, codec interface
  qr/          QR matrix encoding (@ribpay/qr-code-generator) + canvas-grid rendering
  sender/      pipeline (file → frames), pacing/round-robin scheduling, display loop, controls
  receiver/    camera, zxing-wasm decode pool, frame buffer (dedup/eviction),
               reassembly (fountain → inflate → verify), orchestration, save
  ui/          Preact views: App shell, SenderView/Broadcast, ReceiverView, StatusOverlay
  workers/     decode.worker.ts (zxing wasm per worker)
tests/
  unit/        318 unit tests (protocol golden vectors, loss-injected round-trips,
               mid-stream join, tamper rejection, save sanitization, pacing, stats)
  soak/        loss-model matrix over sizes/profiles (default ≤1 MB, SOAK_FULL=1 ≤10 MB, 115 rows)
  e2e/         Playwright: virtual-camera transfers (byte-identical + mid-broadcast join),
               PWA offline, perf budgets
docs/
  PERF.md            measured performance envelope + budgets
  ARCHITECTURE.md    system architecture, wire protocol, profiles, design rationale
  DEVICE-MATRIX.md   camera/device measurement runbook
  THREAT-MODEL.md    security model (no network, no encryption — what that means)
  decisions/raptorq.md  ADR: fountain codec adoption spike
```

## Testing guide

```bash
npm run tsc          # typecheck
npm test             # 318 unit tests (vitest)
npm run lint         # eslint
npx prettier --check .   # formatting
npm run build        # tsc + vite build (also regenerates the service worker precache)
npx playwright test  # all e2e specs (transfer, pwa-offline, perf) — needs `npm run build` first
npm run soak         # default soak (≤1 MB), writes tests/soak/soak-report.txt
npm run soak:full    # full soak (≤10 MB, ~115-row matrix)
npm run perf         # measured unit budgets (Node)
npm run perf:e2e     # real-browser broadcast loop budgets
```

## Security model

There is no network, no pairing and **no encryption** — a deliberate decision for a
same-room broadcast channel. The integrity guarantees that DO exist: per-frame CRC-32C
(rejects corruption), RaptorQ erasure resilience, and a whole-file SHA-256 gate before any
file is offered for saving (a mismatch is surfaced as HASH MISMATCH, never saved). Anything
the camera can see can be read — point the screen at the wall to keep the stream private.
See [THREAT-MODEL.md](docs/THREAT-MODEL.md) for the full model.

## License

No license file is included; the project is `"private": true` (see `package.json`). Third-party
code: RaptorQ wasm is Apache-2.0 (cberner/raptorq), zxing-wasm is Apache-2.0, the QR generator
is MIT, pako is MIT.

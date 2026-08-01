# Performance envelope — measured 2026-08-01

Wave 5 T19: is the QR transfer path actually fast enough? This report records
the real numbers from actual runs, not design guesses. Budgets live in
`tests/unit/perf.test.ts` (Node) and `tests/e2e/perf.spec.ts` (real browser)
and are machine-tolerant on purpose.

## Environment

|               |                                                      |
| ------------- | ---------------------------------------------------- |
| Host          | Linux, 12 cores, Node v22.22.2                       |
| Browser       | Playwright 1.62.1, headless Chromium (chromium-1228) |
| Decode engine | zxing-wasm 3.1.2 (`zxing_reader.wasm` 1.06 MiB)      |
| Encode engine | @ribpay/qr-code-generator (forced mask, Ecc.LOW)     |
| Codec         | raptorq@1.7.24 (grid mtu 1028 / v40 mtu 2052)        |

## 1. Sender encode cost (per-frame QR encode)

`npm run perf` — budget rule: `avgEncodeMs * 1.5 <= frameDelayMs` (the display
loop's own `renderBudgetOk` default margin).

```
[perf] encode V27-L 1024B avg=1.009ms max=2.048ms | frame ~4.04ms vs 42ms   (24fps grid delay)
[perf] encode V40-L 2048B avg=2.233ms max=3.531ms vs delay 83ms             (12fps v40 delay)
```

The **grid frame** (4 tiles + occasional META) costs ~4 ms of encoding against
a 42 ms frame delay — **10× headroom**. The V40 frame costs ~2.2 ms against
83 ms — **37× headroom**. Encode is nowhere near the budget; the adaptive fps
logic (`adaptFps`) is never exercised by encode cost.

## 2. QR render cost (grid frame composition)

```
[perf] renderGrid 4xV27 @4ppm/1600px avg=8.84ms max=12.60ms
[perf] renderSingle V40 @4ppm/1600px avg=6.34ms max=9.44ms
```

A 1600×1600 RGBA grid frame (10.2 MiB, `fill` + 4 tiles) composes in **8.8 ms
avg** — under the 16 ms display-refresh budget with ~1.9× headroom, and under
the grid frame-delay budget (42 ms) with ~4× headroom. Total per-frame work in
the browser loop is ~13 ms (encode + render + putImageData), well inside the
67 ms delay at the app's 15 fps target.

## 3. Decode throughput (receiver)

`decodeImageData` on a 1280×720 frame (the real `downsampleTarget` result of a
1080p capture) containing one V27 QR:

```
[perf] decode 1xV27 1280x720 avg=7.3ms max=8.2ms | ~137 fps single-threaded
```

- **137+ fps single-threaded** — the 5 fps sustained budget has **~27× headroom**.
- Probe (4-tile grid frame, the real broadcast frame, 4×V27 in 1280×720):
  avg 6.0–12 ms → **80–165 fps** depending on tile size.
- With the pool of 4 workers, theoretical pooled throughput is ~550 fps; the
  orchestrator is dispatch-limited to the capture fps (~30–60), so the pool is
  never the bottleneck. **Pool size 4 is fine** (leaving 1 core + main thread).
- Round-robin distribution is exact — `[perf] pool round-robin (size=2, 100
decodes): calls per worker = 50 / 50` — and the pool transfers pixel buffers
  to workers zero-copy (`postMessage` transfer list). No full-frame copies in
  the hot path; `FrameBuffer` dedups by esi with O(1) `Map`/`Set` lookups.

## 4. downsampleTarget

```
[perf] 1920x1080 -> 1280x720 (921600 px)
[perf] 3840x2160 -> 1280x720 (921600 px)
[perf] 1280x720  -> 1280x720 (921600 px)
```

1080p and 4K captures both land at 1280×720 (≤2MP, ≤1280 wide). A 720p camera
capture is already exactly at the target — **there is no benefit to requesting
1080p**; the camera constraints (720p ideal) already feed the decode budget
directly.

## 5. Adaptive pacing boundaries

```
[perf] adaptFps(24,30ms,42ms)->20 | ok(28)=true | ok(30)=false
```

`renderBudgetOk` passes up to 28 ms of work at 24 fps (42 ms delay); over-budget
work steps fps down by 4 (floored at `MIN_FPS`=8). Because measured work is
~13 ms, **the adaptation never fires on this hardware** — the broadcast always
runs at its target cadence.

## 6. Real browser: sender broadcast loop

`npm run perf:e2e` (headless Chromium). The sender is not CPU-bound in the
browser: rAF fires at 60 Hz with an empty callback AND with a 10 MiB
`putImageData` per frame (putImageData itself: **0.54 ms**); the broadcast
callback's measured mean duration is **3.6 ms**.

```
[perf-e2e] grid: samples=16 avgFps=12.0 minFps=12.0 avgTickMs=83.3
[perf-e2e] grid: chips: perf-64k.bin | 64 KB | GRID 2×2 | k 64 | 12.0 fps | 0 dropped
[perf-e2e] grid: canvas 1600x1600px -> ~6 px/module
[perf-e2e] small: samples=12 avgFps=12.0 minFps=12.0 avgTickMs=83.3
[perf-e2e] small: chips: ... | GRID 2×2 | k 64 | 12.0 fps | 0 dropped
[perf-e2e] small: canvas 800x800px -> ~3 px/module
```

- Sustained **12.0 fps flat, 0 dropped ticks** on both a 1600px and an 800px
  canvas. Under parallel CPU load (running alongside the transfer e2e's 4-worker
  decode pool) the same test measured **10.7 fps avg / 10.0 min** — still far
  above `MIN_FPS`=8, which is why the e2e asserts ≥ 8, not ≥ 10.
- **Key finding — 60 Hz rAF quantization**: the app targets 15 fps
  (`computeFrameDelayMs(15)` rounds 66.7 → **67 ms**), but on a 60 Hz display
  the first rAF callback at/after 67 ms is at **83.3 ms**, so the real cadence
  is **12 fps**. Same story at the grid cap: 24 fps targets a 42 ms delay,
  which quantizes to 50 ms → **20 fps actual**. The v40 cap (12 fps → 83 ms
  delay) is exact. This is a pacing-accuracy artifact, not a performance
  defect: at 12 fps a QR still spans ~5 camera frames at 60 Hz capture.

## 7. End-to-end throughput (T18 virtual-camera e2e)

T18's `tests/e2e/transfer.spec.ts` (virtual camera: sender canvas →
`captureStream` → receiver decode → RaptorQ → SHA-256 verify → save) was green
in this run. Wall-clock transfer times:

| fixture            | size                 | wall time                 | effective rate |
| ------------------ | -------------------- | ------------------------- | -------------- |
| fixture-1m.bin     | 1 MiB random         | 23.0 s                    | ~46 KB/s       |
| fixture-512k.png   | 512 KiB random       | 11.8 s                    | ~44 KB/s       |
| fixture-256k.txt   | 256 KiB compressible | 4.7 s                     | ~56 KB/s       |
| fixture-64k.bin    | 64 KiB random        | 3.3 s                     | ~20 KB/s       |
| join-mid-broadcast | 64 KiB random        | 4.6 s (incl. 2.5 s delay) | n/a            |

(The 1 MiB fixture ran 36.5 s → ~28 KB/s when the grid perf spec was driving
the same page concurrently; the table above is the clean, serialized run. Small
files are dominated by fixed startup, so their KB/s looks lower.)

Rates are dominated by QR frame rate × symbols-per-frame, not by decode cost —
the decode budget (section 3) has 27× headroom, so the ceiling is the sender's
12 fps × 4 tiles = 48 symbols/s. At 1024 B/symbol that is ~48 KB/s raw;
compression and repair overhead account for the rest.

## 8. Defects found & fixed

**None in this pass.** Every budget measured above holds with ≥ 1.9× headroom;
the receiver hot path is Map/Set-based with zero-copy worker transfer, the pool
round-robins exactly, and `downsampleTarget` math is correct. No `src/**`
changes were warranted — the design's margins are genuine, not accidental.

## 9. Findings worth acting on (not perf defects)

1. **`chooseProfile` is not wired into the broadcast path.** `prepareTransfer`
   defaults to `grid` and nothing in `src/ui/SenderBroadcast.tsx` consults the
   canvas size, so the app always broadcasts the 2×2 grid. On a phone-size
   canvas (e.g. 375 px) that renders **~1 px/module tiles — undecodable**. The
   V40 profile is unreachable from the UI. Recommendation: pass the profile
   from the view (`chooseProfile(targetFps, canvasSize)`) so small screens fall
   back to a single V40 tile.
2. **15 fps target → 12 fps actual on 60 Hz displays** (rAF quantization, see
   §6). If exact rates matter, target 60 Hz-aligned values (12 / 20 / 30) or
   carry the rAF phase into `computeFrameDelayMs`.
3. **Pool size 4 is generous but safe** — decode has ~27× headroom even at 4
   workers; there is no reason to shrink it.
4. **Keep capture at 720p** — the downsample already yields 1280×720 for 1080p
   and 4K captures, so a higher capture resolution adds camera cost with zero
   decode benefit.

## How to reproduce

```
npm run perf        # unit budgets + measured numbers (Node)
npm run perf:e2e    # real-browser broadcast loop (needs `npm run build` first)
```

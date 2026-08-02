# Device Matrix Runbook: QRStream

Manual QA guide for verifying the offline QR file-transfer PWA on real hardware.
A human (or a device-farm runner) follows this on iOS Safari, Android Chrome,
Desktop Chrome/Firefox, and Safari macOS to prove the sender/receiver matrix
works end to end.

Everything here maps to the implemented code: the button labels, the overlay
readouts, the camera constraints, the profile, and the failure messages are
the real strings from `src/ui/` and `src/receiver/`. Where a number is an
expected range rather than a measured one, it is marked as such.

Status of the automated suite at the time of writing: unit + e2e + soak tests
green. This runbook covers what CI cannot: real cameras, real screens, real
distances, and real hands.

---

## 1. Purpose

This matrix exists to catch the things headless tests can't:

- whether a real camera decodes the grid at the distances people actually hold
  phones;
- whether autofocus/exposure hunting stalls the decode loop on a given device;
- whether the PWA installs and reloads offline on each platform;
- whether saving works (File System Access picker vs. plain download);
- whether rotating the screen mid-transfer kills or recovers a session.

The pass bar for every transfer is the same: the receiver shows the
`✓ VERIFIED (SHA-256)` badge and the received file is byte-identical to the
sent one (checked with `sha256sum`).

---

## 2. Build and serve

### Verified commands

```bash
# production build (type-checks with tsc, emits dist/ + service worker)
npm run build

# serve the built app on the LAN
npm run preview -- --host 0.0.0.0 --port 4173
```

These were run against this repo and confirmed working: `npm run build`
completes with a PWA service worker (12 precache entries), and the preview
server answers HTTP 200 for `/`, `/sw.js`, and `/manifest.webmanifest`.

To reach it from a phone, open `http://<your-LAN-IP>:4173` on the device
(find the IP with `ip addr` on Linux or `ipconfig getifaddr en0` on macOS).

Development server, if you prefer live code:

```bash
npm run dev -- --host 0.0.0.0
```

### Camera needs a secure context: read this before testing RECEIVE

`getUserMedia` (the camera) only works in a **secure context**: HTTPS, or
`http://localhost` / `http://127.0.0.1`. A plain `http://<LAN-IP>:4173` link
**will not give the phone a camera**. The app handles this gracefully: the
receiver shows the friendly message "Camera permission was denied. Allow camera
access for this site in your browser settings, then try again." That is the
insecure-context rejection, not a real permission denial.

The SEND side needs no camera, so plain-HTTP LAN IP is fine for sender-side
testing and for a desktop receiver using its webcam.

Two caveats to keep you from wasting time:

- `npm run dev -- --host --https` does **not** work with this project's Vite
  (8.2). The CLI has no `--https` flag (verified against `vite --help`,
  `vite dev --help`, `vite preview --help`), and Vite will not generate a
  self-signed certificate for you. Skip that recipe.
- To serve HTTPS yourself you would edit `vite.config.ts` to add
  `server: { https: { key, cert } }` (and `preview.https`) using a cert from
  `mkcert`. That is a code change, out of scope for this runbook, but it is the
  one self-contained HTTPS path if you want it.

### Recipes that actually work for camera testing

| Target                                          | Recipe                                                                                                                                                                    | Notes                                                                                                                |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Android Chrome** (recommended, zero internet) | `npm run preview -- --host 0.0.0.0 --port 4173`, then `adb reverse tcp:4173 tcp:4173` (phone on USB, debugging on). Open `http://localhost:4173` on the phone.            | `localhost` counts as a secure context, so camera + service worker both work. Fully offline.                         |
| **iOS Safari**                                  | HTTPS tunnel in front of preview: `npx localtunnel --port 4173` or `cloudflared tunnel --url http://localhost:4173`, then open the `https://` URL it prints on the phone. | Needs internet on the phone; the app itself keeps working offline after first load via the precached service worker. |
| **Android or iOS, no USB, no tunnel**           | Self-signed HTTPS via `mkcert` + `server.https` config (see above).                                                                                                       | The phone shows a certificate warning once; accept it and camera works.                                              |

You only need the camera on the **receiver**. Test send-only paths over plain
HTTP freely.

---

## 3. Test files

Prepare three fixtures on the sender device. The app's own icons are handy
PNGs; for the 1 MB file use random bytes so a byte-identity check is
meaningful.

| Fixture                                           | Why                                                                                                          |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `hello.txt` (a few lines of text)                 | Fastest end-to-end sanity run; proves metadata (filename/mime) arrives.                                      |
| `icon-512.png` (the app's own PNG from `public/`) | Binary file with a real extension and MIME; proves PNG bytes and name survive.                               |
| `test-1mb.bin` (1 MiB of random bytes)            | Proves throughput and reassembly at scale. Generate with `dd if=/dev/urandom of=test-1mb.bin bs=1M count=1`. |

Size note: the wire protocol caps a compressed payload at 16 MiB. Files whose
compressed size exceeds that fail at prepare time with the app's
`TOO_LARGE` error. Keep test files well under it (1 MB is fine; a 10 MB
incompressible file is still under it).

---

## 4. What the UI says (so you verify the right strings)

Real labels from the code, so a device-farm script can assert on them:

- Home: buttons `SEND` and `RECEIVE`, heading "QRStream".
- Sender, pick phase: "Send a file", button `Choose a file`, "or drag & drop it anywhere in this box".
- Sender, settings phase (after preparing): a panel with the file name/size, a profile chip like `V27 · 2×2`, and selectors `Display fps` (12/15/24/30), `Bytes per tile` (1/2/2.5 KB), `Tile layout` (1×1/1×3/3×1/2×2/3×3, the auto-suggested one tagged `recommended`), `High refresh rate` (switch, enabled when a ≥ 90 Hz display is detected), and `Expected speed` (`~N KB/s · ~ETA`). Buttons `Begin broadcast` and `Different file`.
- Sender, broadcasting: chips for filename, size, profile (`V27 · 2×2` style), estimated rate (`KB/s`), `k N`, `N.N fps`, `N dropped`, and elapsed time. Buttons: `Fullscreen`, `Stop`.
- Receiver, idle: "Scan a broadcast", button `Start scanning`.
- Receiver, scanning: chips `SCANNING` then `TRANSFERRING`; once complete, badge `✓ Verified — file complete` and button `Save file`. Errors show `Try again`.
- Status overlay (bottom of the receiver): status chip (`IDLE`/`SCANNING`/`TRANSFERRING`/`COMPLETE`/`ERROR`), `✓ VERIFIED (SHA-256)` or `HASH MISMATCH` badge, a progress bar, `unique / k` counter, filename, and a 4-cell readout: `Decode` (fps), `Speed` (KB/s), `ETA`, `Dropped`.
- After saving: "File saved" with "Saved as <name>." plus `Scan another` and `Back home`.

There is no torch or zoom button anywhere in the app. Do not test one; the
app does not expose camera torch/zoom controls. (Some camera apps have their
own flash, but the PWA has no such UI.)

---

## 5. Device matrix

For each row, run all three fixtures (text, PNG, 1 MB) and record results in
the verdict template (section 10). Pass criteria are the same every row:

- receiver shows `✓ VERIFIED (SHA-256)`;
- received file name, extension, and MIME match the sent file (check "Saved as <name>");
- `sha256sum sent-file received-file` matches (byte-identical).

Timing expectations per size: see section 9.

| #   | Sender → Receiver                               | Expected behavior                                                                                        | What to verify                                                                                                                                                                 | Notes                                                                                                                                                             |
| --- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | iOS Safari → iOS Safari                         | Full phone-to-phone over camera, no network. Receiver shows filename, unique/k climbs, VERIFIED appears. | 1 MB completes with no manual re-aiming. Orientation rotation mid-transfer does not stop it (see §7).                                                                          | Strongest real-world case; the fastest measured path.                                                                                                             |
| 2   | iOS Safari → Android Chrome                     | Same as above; cross-platform metadata must arrive (filename/mime).                                      | PNG name and extension preserved. 1 MB completes.                                                                                                                              |                                                                                                                                                                   |
| 3   | Android Chrome → iOS Safari                     | Same.                                                                                                    | 1 MB completes. Rotation on either device recovers or has a documented limit (§7).                                                                                             |                                                                                                                                                                   |
| 4   | Android Chrome → Android Chrome                 | Same.                                                                                                    | Fastest practical check on cheap hardware. 1 MB completes.                                                                                                                     |                                                                                                                                                                   |
| 5   | Desktop Chrome → iOS Safari                     | Sender on desktop (fullscreen the QR), receiver on phone.                                                | Hold 40-70 cm, steady. 1 MB completes.                                                                                                                                         | Sender needs no camera, so plain-HTTP serving is fine.                                                                                                            |
| 6   | Desktop Chrome → Android Chrome                 | Same.                                                                                                    | Same.                                                                                                                                                                          |                                                                                                                                                                   |
| 7   | Android Chrome → Desktop Chrome (laptop webcam) | Receiver is a laptop camera scanning the phone screen.                                                   | Laptop webcams have a ~30 cm near-focus limit: you must hold the phone **at least ~30 cm** from the camera. Confirm the full-grid fill guidance (§8) before expecting decodes. | Slowest path; phone screens are small in a webcam view. If it stalls, drop to the 1×1 layout in the settings panel (one large QR fills more of the webcam frame). |
| 8   | iOS Safari → Desktop Chrome (laptop webcam)     | Same as 7.                                                                                               | Same.                                                                                                                                                                          |                                                                                                                                                                   |
| 9   | Desktop Firefox → Android Chrome                | Desktop Firefox as sender.                                                                               | Firefox renders the same canvas pipeline; confirm fps chip shows ~15.0 fps and the grid is crisp fullscreen.                                                                   | Firefox is a secondary sender; no camera involved.                                                                                                                |

---

## 6. Per-device checklist

Run each numbered check and mark pass/fail in the verdict template. Every item
here matches a real code path or UI element.

### iOS Safari

1. **Install / offline**: open the app over a working recipe (§2), `Add to Home Screen`, close the tab, disable Wi-Fi/cellular, launch from the home screen. It must load fully (both wasm files precached) and show the home screen.
2. **Camera permission**: tap `RECEIVE` → `Start scanning`. Safari prompts for camera; **Allow**. The view shows the live camera preview and the `SCANNING` chip.
3. **Deny path**: restart the flow, deny the camera prompt. Expect the friendly "Camera permission was denied…" banner and a `Try again` button. No crash.
4. **Send**: `SEND` → `Choose a file` → pick a fixture. Wait for preparation, then review the settings panel (auto-suggested layout and high-refresh; chip like `V27 · 2×2`). `Begin broadcast`. The QR grid is visible; `Fullscreen` works (iOS supports it since 12); the wake lock is held automatically.
5. **Receive**: point at a sender, keep steady. Progress advances (`unique / k`), `Decode` shows live fps, `Speed`/`ETA` populate, then `✓ VERIFIED (SHA-256)` and `✓ Verified — file complete`. `Save file` opens the iOS share sheet (download path, since iOS Safari has no File System Access API). Verify the downloaded name/extensions.
6. **Orientation**: repeat a small transfer in portrait and in landscape. Both must work. Rotate the receiver mid-transfer: it should continue (see §7 for the documented limit).

### Android Chrome

1. **Install / offline**: `Add to Home screen`, close, go offline, relaunch. Must load offline from the precache.
2. **Camera permission**: `Start scanning` → **Allow**. Camera preview + `SCANNING` chip.
3. **Deny path**: deny once, expect the friendly banner and `Try again`.
4. **Send**: same flow as iOS. `Fullscreen` works; the wake lock is held automatically (screen stays awake).
5. **Receive**: same flow. `Save file` uses the File System Access picker on Android Chrome (a real save dialog appears). Name it whatever you like; the "Saved as <name>" line reflects the picker's choice.
6. **Orientation**: portrait and landscape both fine. Rotation mid-transfer recovers (or note the limit per §7).

### Desktop Chrome (sender or receiver)

1. **Install / offline**: the address-bar install icon appears (manifest is valid). Install, disconnect network, relaunch, app loads offline.
2. **Camera (receiver role)**: `Start scanning` → **Allow**. Same overlay as phones. Save uses the File System Access picker; canceling it shows a "saving was cancelled" message and you can hit `Save file` again.
3. **Send**: `Fullscreen` (F11-like, enters fullscreen on the QR stage), `Stop`. The `N.N fps` chip should read ~15.0 for the grid; `N dropped` should stay low.
4. **Drag & drop**: the dropzone accepts a dragged file (drag state highlights the box).
5. **Orientation**: desktop is effectively landscape; window resize mid-broadcast re-scales the grid. Confirm it keeps decoding after a resize.

### Desktop Firefox

1. **Install / offline**: add-to-home-screen equivalent (Firefox's "Install" in the menu), offline reload works.
2. **Send**: grid renders, ~15.0 fps chip. Fullscreen works; the wake lock is held automatically. Firefox is a supported sender (matrix row 9).
3. **Camera**: if you test Firefox as a receiver, confirm the permission prompt and that `facingMode: environment` resolves (on a laptop with no rear camera this may pick the webcam; if it fails you get the typed "camera could not match the requested settings" message, which is the correct behavior).

### Safari macOS

1. **Install / offline**: Safari on macOS has no add-to-homescreen; the equivalent is a pinned tab or the Share menu "Add to Dock" (via the app's manifest). Offline reload works once the SW has cached.
2. **Send**: identical pipeline to Chrome; confirm the grid and fps chip.
3. **Camera (receiver role)**: Safari macOS grants camera; the app works as a receiver using the built-in webcam at ~30 cm+ distance. Save uses the download path (Safari has no File System Access API).
4. **Orientation**: not applicable (desktop), but window resizing must not kill a broadcast.

---

## 7. Camera-specific checks

These go beyond "does it transfer" and into the physics that decide whether
it transfers at all. Do them once per device family and record the numbers.

### Near/far distance test (record max usable distance)

1. Put the sender in fullscreen (the wake lock keeps the screen on automatically), brightness max.
2. Start a 1 MB broadcast. On the receiver, start scanning and slowly move it **backward** from ~30 cm until decodes stop (`Decode` drops to ~0.0 fps and `unique` stops climbing).
3. Record that max distance. Expected ballpark: **40-70 cm** for phone-to-phone. Past ~70 cm the grid falls below the px/module floor and decodes vanish; too close (< ~30 cm on phones, < ~30 cm on laptop webcams) goes out of focus and blurs.
4. Repeat moving **forward** to find the near-focus limit (where the QR goes soft).

### Autofocus lock behavior

The app requests `focusMode: continuous` and then best-effort locks focus and
exposure (`tryLockFocusExposure`). What you should observe:

- When the receiver is held **steady**, `Decode` fps stays high and `unique`
  climbs smoothly.
- With hand tremor or rapid re-aiming, `Decode` fps drops sharply. That is the
  autofocus/exposure hunting that kills throughput.
- **Fix**: prop the phone against something, or brace elbows. A phone that is
  stationary for the whole transfer is the single biggest throughput lever.

### Exposure on a bright screen

With max brightness and a bright room, exposure auto-adjusts and can make the
black QR modules look gray. Expect occasional decode stalls; the counter
recovers once exposure settles. **Guidance**: dim the room, avoid direct light
on the sender screen, and keep the receiver roughly perpendicular to the
screen (avoid tilting so the QRs look trapezoidal).

### Reflections and glare test

- Tilt the sender or receiver so a lamp/window reflects off the screen. Decodes
  stop or slow to a crawl in the glare band.
- **Pass** is: glare-free angle decodes fine; you can find a glare-free angle
  easily. Record the worst angle in notes if a device is unusually glossy.

### Torch / zoom

The app exposes **no** torch or zoom controls. Skip any such test; there is
nothing to verify.

### Phase drift (why steady hands and a fixed distance matter)

The sender runs below the camera's capture rate on purpose so the QR refresh
phase-drifts across capture frames (aliasing would re-show the same frame).
Because of this, a receiver held perfectly still will still collect every
symbol; a receiver jittering will miss whole capture frames. This is the
mechanism behind "keep it steady", not folklore.

---

## 8. px/module guidance (how close must the phone be?)

The app does not print its px/module figure anywhere, so this runbook uses the
fill-fraction proxy. The rule from measurement: a QR needs roughly
**3.5-4 px per module in the camera's view** to decode reliably (3.7 px/module
≈ 100% decode rate; 3.4 px/module ≈ 0%). The sender helps by fullscreening the
QR, which on a typical phone or 1080p desktop renders the grid at ~4 px/module
on the sending screen itself.

**Manual check for the tester:** hold the phone so the QR grid fills about
**60-70% of the viewfinder** (the whole 2×2 block, not a corner). You can be
more precise with this calibration: at a typical 1280 px-wide camera frame the
grid must span at least ~83% of the frame width to reach 4 px/module, so
"most of the viewfinder" is the honest target. If `Decode` fps is healthy but
`unique` never climbs, get closer until the grid is unmistakably most of the
frame.

Rules of thumb:

- Fullscreen the sender QR (the `Fullscreen` button). A small windowed QR
  starves the camera of pixels.
- Phones: 40-70 cm. Laptop webcams: at least ~30 cm (their near-focus floor)
  and usually farther.
- When in doubt, closer is better, until the picture blurs (that is the
  autofocus near limit, back off a little).

---

## 9. Failure-mode playbook

Symptom → likely cause → fix. These map to real code paths; the friendly
messages in quotes are the app's own strings.

| Symptom                                                               | Cause                                                                                                      | Fix                                                                                                                                  |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Receiver shows "Camera permission was denied…" immediately, no prompt | Insecure context (plain HTTP LAN IP) or permission revoked                                                 | Use a §2 recipe (adb reverse, tunnel, or HTTPS). Otherwise tap `Try again` after allowing in site settings.                          |
| No decodes at all (`Decode` ~0.0 fps, `unique` stays 0)               | Too close (blur), too far (< 3.5 px/module), autofocus hunting, or a reflection across the grid            | Re-aim to 40-70 cm, grid filling most of the frame, perpendicular, glare-free, phone braced.                                         |
| `unique` climbs then stalls at `k/2` (or some fraction)               | Still scanning a partial set; RaptorQ needs `k` distinct packets, and repair symbols let it recover losses | Keep scanning, stay steady. The sender re-broadcasts metadata every 32 ticks (~2 s), so a receiver that joined late will pick it up. |
| Stuck on `SCANNING` with no filename shown                            | Metadata frame not yet decoded (sender re-broadcasts it every 32 ticks)                                    | Keep scanning; within ~2 s of the next metadata tick the filename and `k` should appear. If it never does, you're too far/small.     |
| `VERIFIED (SHA-256)` never appears though `unique` looks complete     | Missing distinct symbols (a few lost frames), usually from hand shake                                      | Stay absolutely still; repair symbols in the sender's pool (k + ~30% + 100) cover the loss.                                          |
| `HASH MISMATCH` badge                                                 | Reassembled bytes failed the SHA-256 check                                                                 | Restart the scan (`Restart scan` button) and redo the transfer. Should be vanishingly rare with a clean capture.                     |
| `Save file` fails / "saving was cancelled"                            | File System Access picker was canceled, or browser denied it                                               | Hit `Save file` again and pick a destination. On iOS it is a download, not a picker.                                                 |
| Sender "Preparing" fails with a too-large error                       | Compressed payload exceeds the 16 MiB wire limit                                                           | Pick a smaller file.                                                                                                                 |
| Sender `N dropped` climbing steadily                                  | Encode/render is over budget; the loop throttles fps down automatically                                    | Lower the window resolution or use a faster device. Throttling to a lower fps is expected behavior, not a bug.                       |
| Receiver "The camera is in use by another application."               | Another app (e.g. the camera app) holds the camera                                                         | Close it and tap `Try again`.                                                                                                        |

---

## 10. Speed expectations

Measured end-to-end numbers live in `docs/PERF.md` (§7); this table is the practical
expectation band for manual runs, recorded with the default settings (2×2 grid, 1 KB tiles,
15 fps target).

| Payload              | Expected time                                                                                                                    | Notes                                                                                      |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| 1 MB                 | ~20-60 s                                                                                                                         | At default grid throughput; smaller text/PNG files are much faster (single-digit seconds). |
| 10 MB                | ~3-10 min                                                                                                                        | Longest practical transfer; battery/brightness matter, keep the sender plugged in.         |
| Effective throughput | Default 2×2 / 1 KB / 15 fps measures ~44-56 KB/s (PERF.md §7); more tiles, larger tiles or higher fps (90 Hz+ display) go faster | The app defaults to 2×2 at 15 fps; raise it in the settings panel on capable hardware.     |

Reading the on-screen numbers: the overlay's `Speed` is live KB/s over the last
half-second, `ETA` is the projected remaining time from that speed, `Decode`
is how many frames per second the pool actually decodes (healthy is roughly
your camera's capture fps), and `Dropped` counts frames skipped because the
decode pool was saturated. On the sender, the `N.N fps` chip is the real
rendered rate (target ~15.0 fps for the grid) and `N dropped` is encode
failures.

Use the sender's elapsed chip and the receiver's `ETA` to sanity-check each
other during a run.

---

## 11. Verdict template

Copy this table once per device tested and attach it to the run. The "Matrix
rows" column is the §5 row numbers that device participated in.

**Device:** \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_ (make/model)

**OS version:** \_\_\_\_\_\_\_\_\_\_\_\_ · **Browser:** \_\_\_\_\_\_\_\_\_
**version:** \_\_\_\_\_\_\_\_ · **Role(s):** SENDER / RECEIVER / BOTH
**Matrix rows:** \_\_\_\_\_\_\_\_

| Check (from §6-§8)               | Result (PASS / FAIL / N/A) | Notes |
| -------------------------------- | -------------------------- | ----- |
| Install / add-to-homescreen      |                            |       |
| Offline reload after install     |                            |       |
| Camera prompt → Allow works      |                            |       |
| Deny path shows friendly error   |                            |       |
| Send: pick → prepare → broadcast |                            |       |
| Fullscreen button                |                            |       |
| Wake lock (automatic)            |                            |       |
| Receive: unique/k advances       |                            |       |
| Receive: Speed + ETA shown       |                            |       |
| VERIFIED badge appears           |                            |       |
| Save file (picker or download)   |                            |       |
| Saved name/extension/mime match  |                            |       |
| sha256sum matches sent file      |                            |       |
| Orientation portrait             |                            |       |
| Orientation landscape            |                            |       |
| Rotation mid-transfer            |                            |       |
| Max usable distance (record cm)  |                            |       |
| Near-focus limit (record cm)     |                            |       |
| Reflections/glare test           |                            |       |

**Tested sizes:** text (…) / PNG (…) / 1 MB (…)

**Speed observed:** \_\_\_\_\_\_ KB/s average (sender chip vs. receiver overlay)

**Overall verdict:** PASS / FAIL (FAIL: blocker in notes)

**Notes:** \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

---

## 12. Running order for a device-farm runner

1. Build and serve once per host (`npm run build`, then preview + the
   §2 recipe matching the receiver platform).
2. For each receiver device: install checks (§6), then camera checks (§7).
3. Run the matrix rows (§5) for that device, smallest fixture first.
4. Record the verdict (§11) and move on. Any FAIL with a matching playbook row
   (§9) should note the fix and be retried once before being marked as a
   device-specific defect.

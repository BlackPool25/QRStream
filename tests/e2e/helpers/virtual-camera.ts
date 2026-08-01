/**
 * Virtual-camera wiring for the transfer e2e (scenario contract S1).
 *
 * The receiver's "camera" is a REAL MediaStream produced by
 * `canvas.captureStream(30)` on the sender page's broadcast canvas. The
 * receiver page is opened as a popup of the sender, so it can read
 * `window.opener.__senderStream` across realms (MediaStreams are not
 * structured-cloneable, but same-origin windows share live object
 * references). getUserMedia is replaced with a stub that resolves to that
 * stream; the FSA save picker is stubbed to capture the written bytes.
 */

import { expect, type BrowserContext, type Page } from '@playwright/test'
import type { TransferFixture } from './fixtures'
import {
  applySenderSettings,
  clickBeginBroadcast,
  waitForSettingsPanel,
  type SenderSettingsOverride,
} from './sender-settings'
export type { SenderSettingsOverride } from './sender-settings'

/** Square sender viewport: a 1440px canvas renders 5px/module V27 tiles. */
export const SENDER_VIEWPORT = { width: 1440, height: 1440 } as const

/** One entry captured by the FSA save-picker stub. */
export interface SavedEntry {
  readonly name: string
  readonly bytes: Uint8Array
  /** Mime keys from the picker options' accept map (proves mime preservation). */
  readonly mimeTypes: readonly string[]
}

declare global {
  interface Window {
    __senderStream: MediaStream
    __saved: readonly SavedEntry[]
  }
}

export interface StartSenderBroadcastOptions {
  /** Settings to apply on the settings phase before beginning the broadcast. */
  readonly settings?: SenderSettingsOverride
}

/**
 * Drives the real sender UI to broadcast `fixture`: pick → settings phase →
 * broadcast. Applies any settings overrides, then exposes
 * `window.__senderStream` = canvas.captureStream(30) on the page. Returns the
 * sender page (kept alive for the receiver's stream).
 */
export async function startSenderBroadcast(
  context: BrowserContext,
  fixture: TransferFixture,
  opts: StartSenderBroadcastOptions = {},
): Promise<Page> {
  const sender = await context.newPage()
  await sender.setViewportSize(SENDER_VIEWPORT)
  if (opts.settings?.highRefresh === true) {
    // Fake a >=90 Hz display BEFORE the app probes it: detectRefreshRate reads
    // the __qrRefreshRateOverride hook first, which is what enables the
    // high-refresh switch (and the 30 fps option) on the settings panel.
    await sender.addInitScript(() => {
      window.__qrRefreshRateOverride = 120
    })
  }
  await sender.goto('/')
  await sender.getByRole('button', { name: 'Send a file' }).click()
  await sender.locator('input[type="file"]').setInputFiles({
    name: fixture.name,
    mimeType: fixture.mime,
    buffer: fixture.bytes,
  })
  await waitForSettingsPanel(sender)
  await applySenderSettings(sender, opts.settings ?? {})
  await clickBeginBroadcast(sender)
  await waitForQrCanvas(sender)
  await sender.evaluate(() => {
    const canvas = document.querySelector('canvas.qr-canvas')
    if (!(canvas instanceof HTMLCanvasElement)) {
      throw new Error('broadcast canvas not found')
    }
    window.__senderStream = canvas.captureStream(30)
  })
  return sender
}

/**
 * Opens the receiver as a popup of `sender` (same origin, same context) and
 * replaces `navigator.mediaDevices.getUserMedia` with a stub that resolves to
 * the sender's live capture stream. The app only calls getUserMedia when the
 * user clicks "Start scanning", so installing the stub after load is safe.
 */
export async function openReceiverWithVirtualCamera(
  context: BrowserContext,
  sender: Page,
): Promise<Page> {
  const [receiver] = await Promise.all([
    context.waitForEvent('page'),
    sender.evaluate(() => {
      const opened = window.open('/', '_blank')
      if (opened === null) {
        throw new Error('window.open was blocked')
      }
    }),
  ])
  await receiver.waitForLoadState('domcontentloaded')
  await receiver.evaluate(() => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: async (): Promise<MediaStream> => {
          const opener = window.opener as Window | null
          const stream = opener?.__senderStream
          if (stream === undefined) {
            throw new Error('sender broadcast stream not ready')
          }
          return stream
        },
        getSupportedConstraints: () => ({ frameRate: true }),
        enumerateDevices: async (): Promise<MediaDeviceInfo[]> => [],
      },
    })
  })
  return receiver
}

/**
 * Replaces `window.showSaveFilePicker` with a double that captures the written
 * bytes into `window.__saved`. save.ts feature-detects at save time
 * (`typeof window.showSaveFilePicker === 'function'`), so installing the stub
 * any time before the "Save file" click is sufficient.
 */
export async function stubSaveFilePicker(page: Page): Promise<void> {
  await page.evaluate(() => {
    // page.evaluate serializes this callback: it must be fully self-contained.
    const chunkToBytes = (data: FileSystemWriteChunkType): Uint8Array => {
      if (data instanceof ArrayBuffer) {
        return new Uint8Array(data)
      }
      if (ArrayBuffer.isView(data)) {
        return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
      }
      if (typeof data === 'string') {
        return new TextEncoder().encode(data)
      }
      // saveViaFsa only ever passes a Uint8Array; Blob/WriteParams would be a bug.
      throw new TypeError(`unexpected write chunk: ${typeof data}`)
    }
    const saved: SavedEntry[] = []
    window.__saved = saved
    window.showSaveFilePicker = async (
      opts?: SaveFilePickerOptions,
    ): Promise<FileSystemFileHandle> => {
      const name = opts?.suggestedName ?? ''
      const mimeTypes = Object.keys(opts?.types?.[0]?.accept ?? {})
      const handle: FileSystemFileHandle = {
        kind: 'file',
        name,
        isSameEntry: async () => false,
        createSyncAccessHandle: async () => {
          throw new Error('createSyncAccessHandle is not used by saveViaFsa')
        },
        createWritable: async (): Promise<FileSystemWritableFileStream> => ({
          locked: false,
          abort: async () => {},
          close: async () => {},
          getWriter: () => {
            throw new Error('getWriter is not used by saveViaFsa')
          },
          seek: async () => {},
          truncate: async () => {},
          write: async (data: FileSystemWriteChunkType): Promise<void> => {
            saved.push({ name, bytes: chunkToBytes(data), mimeTypes })
          },
        }),
        getFile: async () => {
          throw new Error('getFile is not used by saveViaFsa')
        },
      }
      return handle
    }
  })
}

/** Polls until the broadcast canvas holds non-blank pixels (first QR frame). */
async function waitForQrCanvas(page: Page): Promise<void> {
  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const canvas = document.querySelector('canvas.qr-canvas')
          if (!(canvas instanceof HTMLCanvasElement) || canvas.width === 0) {
            return 0
          }
          const ctx = canvas.getContext('2d')
          if (ctx === null) {
            return 0
          }
          const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height).data
          let sum = 0
          for (let i = 0; i < pixels.length; i += 16) {
            sum += pixels[i] ?? 0
          }
          return sum
        }),
      { timeout: 20_000, message: 'broadcast QR canvas never rendered non-blank content' },
    )
    .toBeGreaterThan(0)
}

/**
 * Asserts the receiver's StatusOverlay shows decoded symbols (unique / k
 * counter advances) — proof the virtual camera is actually feeding the
 * decoder, not silently dead.
 */
export async function waitForSymbolsReceived(page: Page, timeout: number): Promise<void> {
  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const text = document.querySelector('.so-count')?.textContent ?? ''
          const match = /^\s*(\d+)/.exec(text)
          return match === null ? -1 : Number(match[1])
        }),
      { timeout, message: 'receiver never decoded symbols — virtual camera not wired' },
    )
    .toBeGreaterThan(0)
}

/** Asserts the "✓ VERIFIED (SHA-256)" badge is shown (transfer hash-checked). */
export async function waitForVerifiedBadge(page: Page, timeout: number): Promise<void> {
  await expect(page.locator('.so-badge--ok')).toBeVisible({ timeout })
}

/** Reads the bytes captured by the FSA save-picker stub. */
export async function readSavedFiles(page: Page): Promise<readonly SavedEntry[]> {
  return page.evaluate(() => window.__saved)
}

import { expect, test, type BrowserContext } from '@playwright/test'
import {
  buildCompressibleText,
  buildRandomBytes,
  sha256Hex,
  type TransferFixture,
} from './helpers/fixtures'
import {
  openReceiverWithVirtualCamera,
  readSavedFiles,
  startSenderBroadcast,
  stubSaveFilePicker,
  waitForSymbolsReceived,
  waitForVerifiedBadge,
  type SenderSettingsOverride,
} from './helpers/virtual-camera'

/**
 * Scenario contract S1: two pages in one context — a SENDER broadcasting a 2×2
 * QR grid and a RECEIVER whose camera is a VIRTUAL camera (the sender's canvas
 * via canvas.captureStream + a getUserMedia stub). The full pipeline must run:
 * file → sender display → virtual camera → receiver decode → RaptorQ
 * reassembly → SHA-256 verify → save, byte-identical, with the verified badge.
 *
 * Sizes cover both codec paths: random bytes are incompressible (no-compression
 * wire), the compressible text exercises sender deflate + receiver inflate, and
 * the .png fixture proves mime/extension preservation.
 */
const RANDOM_MIME = 'application/octet-stream'

const FIXTURES: readonly TransferFixture[] = [
  { name: 'fixture-64k.bin', mime: RANDOM_MIME, bytes: buildRandomBytes(64 * 1024, 1) },
  { name: 'fixture-1m.bin', mime: RANDOM_MIME, bytes: buildRandomBytes(1024 * 1024, 2) },
  { name: 'fixture-512k.png', mime: 'image/png', bytes: buildRandomBytes(512 * 1024, 3) },
  { name: 'fixture-256k.txt', mime: 'text/plain', bytes: buildCompressibleText(256 * 1024, 4) },
]

test.describe('end-to-end transfer over the virtual camera', () => {
  // Serial: each transfer drives a broadcast + a 4-worker decode pool, so
  // running them one at a time avoids CPU contention skewing decode rates.
  test.describe.configure({ mode: 'serial' })

  for (const fixture of FIXTURES) {
    test(`receives ${fixture.name} byte-identical and SHA-256 verified`, async ({ context }) => {
      test.setTimeout(timeoutFor(fixture.name))
      await runTransfer(context, fixture, {})
    })
  }

  test('receiver joining mid-broadcast still completes (metadata re-broadcast)', async ({
    context,
  }) => {
    test.setTimeout(120_000)
    const fixture: TransferFixture = {
      name: 'fixture-joinlate.bin',
      mime: RANDOM_MIME,
      bytes: buildRandomBytes(64 * 1024, 5),
    }
    // Join 2.5s late — the META frame is re-broadcast every 32 ticks (~2s).
    await runTransfer(context, fixture, { receiverDelayMs: 2_500 })
  })

  test('receives a non-default-settings broadcast (2.5 KB tiles, 3×1 row) byte-identical', async ({
    context,
  }) => {
    test.setTimeout(120_000)
    const fixture: TransferFixture = {
      name: 'fixture-256k-custom.bin',
      mime: RANDOM_MIME,
      bytes: buildRandomBytes(256 * 1024, 6),
    }
    // Non-default settings must work end-to-end: the sender re-encodes for the
    // 2.5 KB symbol and broadcasts a 3×1 row, and the receiver (profile-
    // agnostic, it reassembles any symbolSize from metadata) still reassembles
    // + SHA-256-verifies the exact same bytes. Same assertions as the defaults.
    await runTransfer(context, fixture, {
      settings: { bytesPerTile: '2.5k', layout: 'row3' },
    })
  })

  test('receives a 2 KB (V34) broadcast byte-identical', async ({ context }) => {
    test.setTimeout(120_000)
    const fixture: TransferFixture = {
      name: 'fixture-256k-2k.bin',
      mime: RANDOM_MIME,
      bytes: buildRandomBytes(256 * 1024, 7),
    }
    // Regression: the 2 KB profile originally used V33 whose forced-mask-2
    // capacity (2068 B) could not hold the 2082 B wire frame, so every tile
    // failed to encode and the broadcast rendered black. V34 (2188 B) fits.
    await runTransfer(context, fixture, {
      settings: { bytesPerTile: '2k', layout: 'grid4' },
    })
  })
})

function timeoutFor(name: string): number {
  if (name === 'fixture-1m.bin') {
    return 180_000
  }
  return 120_000
}

async function runTransfer(
  context: BrowserContext,
  fixture: TransferFixture,
  opts: {
    readonly receiverDelayMs?: number
    readonly settings?: SenderSettingsOverride
  },
): Promise<void> {
  const sender = await startSenderBroadcast(
    context,
    fixture,
    opts.settings === undefined ? {} : { settings: opts.settings },
  )
  if (opts.receiverDelayMs !== undefined) {
    await sender.waitForTimeout(opts.receiverDelayMs)
  }
  const receiver = await openReceiverWithVirtualCamera(context, sender)
  await receiver.getByRole('button', { name: 'Receive a file' }).click()
  await receiver.getByRole('button', { name: 'Start scanning' }).click()

  // The virtual camera must feed real frames: prove decodes happen.
  await waitForSymbolsReceived(receiver, 30_000)
  // Reassembly + SHA-256: the verified badge only renders on a matching hash.
  await waitForVerifiedBadge(receiver, timeoutFor(fixture.name))

  // Save via the stubbed FSA picker; assert the captured bytes match.
  await stubSaveFilePicker(receiver)
  await receiver.getByRole('button', { name: 'Save file' }).click()

  const saved = await readSavedFiles(receiver)
  expect(saved, `exactly one file was saved for ${fixture.name}`).toHaveLength(1)
  const entry = saved[0]
  if (entry === undefined) {
    throw new Error(`no saved file entry for ${fixture.name}`)
  }
  expect(entry.name, 'saved filename matches the broadcast metadata').toBe(fixture.name)
  expect(entry.mimeTypes, 'saved picker mime matches the broadcast metadata').toContain(
    fixture.mime,
  )
  const received = Buffer.from(entry.bytes)
  expect(received.length, 'saved byte length matches the fixture').toBe(fixture.bytes.length)
  expect(received.equals(fixture.bytes), 'saved bytes are byte-identical to the fixture').toBe(true)
  expect(
    sha256Hex(received),
    'independent SHA-256 of the saved bytes equals the fixture hash',
  ).toBe(sha256Hex(fixture.bytes))

  console.log(
    `[transfer] ${fixture.name}: ${received.length} bytes, byte-identical, ` +
      `SHA-256 ${sha256Hex(received).slice(0, 16)}…`,
  )
}

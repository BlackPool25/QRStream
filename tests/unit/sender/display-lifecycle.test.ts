import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { FountainEncoder } from '../../../src/codec/fountain/interface'
import type { TransferSettings } from '../../../src/protocol/constants'
import { SenderDisplay } from '../../../src/sender/display'
import type { PreparedTransfer } from '../../../src/sender/pipeline'

/**
 * SenderDisplay wake-lock lifecycle: the broadcast screen must hold the
 * screen-awake wake lock for the whole broadcast without user interaction.
 *
 * Test seam: SenderDisplay's real requestWakeLock/releaseWakeLock helpers
 * (sender/controls.ts) drive `navigator.wakeLock`, so we stub the Navigator
 * API and let the real helpers run against it — the most faithful contract
 * test: start() must request a 'screen' lock, dispose() must release the
 * sentinel that request returned.
 */

const SETTINGS: TransferSettings = {
  bytesPerTile: '1k',
  layout: 'grid4',
  targetFps: 15,
  highRefresh: false,
}

/** Minimal PreparedTransfer the SenderDisplay constructor actually reads. */
function makePrepared(): PreparedTransfer {
  const encoder: FountainEncoder = {
    symbolSize: 1024,
    sourceSymbolCount: 8,
    encodeSourceSymbols: () => [],
    encodeRepair: () => [],
    dispose: vi.fn(),
  }
  return {
    info: {
      sessionId: 'test-session',
      filename: 'fixture.bin',
      mime: 'application/octet-stream',
      totalSize: 1024,
      compressedSize: 1024,
      compressed: false,
      k: 8,
      symbolSize: 1024,
      mtu: 1028,
      fileSHA256: '0'.repeat(64),
      settings: SETTINGS,
      totalFrames: 9,
      dataFrameCount: 8,
      metaFrameCount: 1,
    },
    dataFrames: [],
    metaFrames: [],
    encoder,
  }
}

function makeCanvas(): HTMLCanvasElement {
  return {
    width: 0,
    height: 0,
    getContext: (kind: string) => (kind === '2d' ? ({} as CanvasRenderingContext2D) : null),
  } as HTMLCanvasElement
}

// SenderDisplay.start() sizes the backing store from window and schedules a
// rAF loop, so the Node test env needs minimal browser-global stubs; they are
// restored after each test (settings.test.ts withWindowMock-style).
const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
const originalNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
const originalRaf = Object.getOwnPropertyDescriptor(globalThis, 'requestAnimationFrame')
const originalCaf = Object.getOwnPropertyDescriptor(globalThis, 'cancelAnimationFrame')

beforeEach(() => {
  Object.defineProperty(globalThis, 'window', {
    value: {
      innerWidth: 1600,
      innerHeight: 1600,
      devicePixelRatio: 1,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    },
    configurable: true,
  })
  Object.defineProperty(globalThis, 'requestAnimationFrame', {
    value: vi.fn(() => 1),
    configurable: true,
  })
  Object.defineProperty(globalThis, 'cancelAnimationFrame', {
    value: vi.fn(),
    configurable: true,
  })
})

afterEach(() => {
  for (const [name, descriptor] of [
    ['window', originalWindow],
    ['navigator', originalNavigator],
    ['requestAnimationFrame', originalRaf],
    ['cancelAnimationFrame', originalCaf],
  ] as const) {
    if (descriptor === undefined) {
      Reflect.deleteProperty(globalThis, name)
    } else {
      Object.defineProperty(globalThis, name, descriptor)
    }
  }
})

describe('SenderDisplay wake-lock lifecycle', () => {
  it('requests a screen wake lock on start() and releases the sentinel on dispose()', async () => {
    const release = vi.fn()
    const request = vi.fn().mockResolvedValue({ release })
    Object.defineProperty(globalThis, 'navigator', {
      value: { wakeLock: { request } },
      configurable: true,
    })

    const display = new SenderDisplay({
      canvas: makeCanvas(),
      prepared: makePrepared(),
      settings: SETTINGS,
    })

    // When: the broadcast starts.
    display.start()
    await Promise.resolve() // flush the async requestWakeLock so it stores the sentinel

    // Then: the wake lock was requested automatically, for 'screen'.
    expect(request).toHaveBeenCalledWith('screen')

    // When: the broadcast screen is torn down.
    display.dispose()

    // Then: the acquired sentinel is released.
    expect(release).toHaveBeenCalledTimes(1)
  })
})

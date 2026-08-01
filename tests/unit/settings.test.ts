import { describe, expect, it, vi } from 'vitest'
import type { TransferSettings } from '../../src/protocol/constants'
import {
  DEFAULT_TRANSFER_SETTINGS,
  detectOrientation,
  detectRefreshRate,
  detectRefreshRateCore,
  transferLabel,
  validateSettings,
  type QrWindow,
} from '../../src/sender/settings'

/**
 * Runs `run` with a stubbed global `window`, restoring the original
 * afterwards so tests never leak mocks into one another (camera.test.ts
 * withNavigatorMock-style global stubbing).
 */
async function withWindowMock<T>(mock: unknown, run: () => Promise<T> | T): Promise<T> {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'window')
  Object.defineProperty(globalThis, 'window', { value: mock, configurable: true })
  try {
    return await run()
  } finally {
    if (descriptor === undefined) {
      Reflect.deleteProperty(globalThis, 'window')
    } else {
      Object.defineProperty(globalThis, 'window', descriptor)
    }
  }
}

/**
 * Drives detectRefreshRateCore with a fake rAF at the given cadence: each
 * callback fires at t = fired × 1000 / hz ms, so the measured rate is
 * exactly `hz` when the window closes on a 1000/hz boundary. Returns the
 * probe promise plus spies for the trailing-cancel assertions.
 */
async function probeRate(hz: number, windowMs = 400) {
  let t = 0
  let nextId = 0
  const pending: FrameRequestCallback[] = []
  const raf = vi.fn((cb: FrameRequestCallback) => {
    pending.push(cb)
    nextId += 1
    return nextId
  })
  const cancel = vi.fn()
  const now = vi.fn(() => t)
  const rate = detectRefreshRateCore(raf, cancel, now, windowMs)
  let fired = 0
  // The probe ends its cadence by canceling the trailing pending frame, so
  // stop driving when cancel fires (as a real browser would).
  while (pending.length > 0 && cancel.mock.calls.length === 0) {
    fired += 1
    t = (fired * 1000) / hz
    const cb = pending.shift()
    cb?.(t)
  }
  return { rate, raf, cancel, fired }
}

describe('DEFAULT_TRANSFER_SETTINGS', () => {
  it('matches the required default shape', () => {
    expect(DEFAULT_TRANSFER_SETTINGS).toEqual({
      bytesPerTile: '1k',
      layout: 'grid4',
      targetFps: 15,
      highRefresh: false,
    })
  })
})

describe('validateSettings', () => {
  it('accepts the default settings', () => {
    expect(() => validateSettings(DEFAULT_TRANSFER_SETTINGS)).not.toThrow()
  })

  it('accepts every valid bytesPerTile/layout/targetFps/highRefresh combination', () => {
    for (const bytesPerTile of ['1k', '2k', '2.5k'] as const) {
      for (const layout of ['single', 'column3', 'row3', 'grid4', 'grid9'] as const) {
        for (const targetFps of [12, 15, 24, 30] as const) {
          for (const highRefresh of [true, false]) {
            expect(() =>
              validateSettings({ bytesPerTile, layout, targetFps, highRefresh }),
            ).not.toThrow()
          }
        }
      }
    }
  })

  it('rejects an unknown bytesPerTile', () => {
    const s = { ...DEFAULT_TRANSFER_SETTINGS, bytesPerTile: '4k' } as unknown as TransferSettings
    expect(() => validateSettings(s)).toThrow(TypeError)
  })

  it('rejects an unknown layout', () => {
    const s = { ...DEFAULT_TRANSFER_SETTINGS, layout: 'hexagon' } as unknown as TransferSettings
    expect(() => validateSettings(s)).toThrow(TypeError)
  })

  it('rejects a disallowed targetFps', () => {
    const s = { ...DEFAULT_TRANSFER_SETTINGS, targetFps: 20 } as unknown as TransferSettings
    expect(() => validateSettings(s)).toThrow(TypeError)
  })

  it('rejects a non-boolean highRefresh', () => {
    const s = { ...DEFAULT_TRANSFER_SETTINGS, highRefresh: 'yes' } as unknown as TransferSettings
    expect(() => validateSettings(s)).toThrow(TypeError)
  })
})

describe('detectRefreshRateCore', () => {
  it.each([
    [60, 60],
    [90, 90],
    [120, 120],
  ])('measures a %i Hz probe as %i Hz and cancels the trailing frame', async (hz, expected) => {
    const { rate, raf, cancel, fired } = await probeRate(hz)
    await expect(rate).resolves.toBe(expected)
    expect(fired).toBeGreaterThan(0)
    // One registration per fired callback plus the initial one; the frame
    // pending past the window is the trailing one and gets canceled once.
    expect(raf).toHaveBeenCalledTimes(fired + 1)
    expect(cancel).toHaveBeenCalledTimes(1)
    expect(cancel).toHaveBeenCalledWith(fired + 1)
  })

  it.each([
    [104, 90],
    [105, 120],
    [74, 60],
    [75, 90],
  ])('classifies the %i Hz boundary as %i Hz', async (hz, expected) => {
    const { rate } = await probeRate(hz)
    await expect(rate).resolves.toBe(expected)
  })
})

describe('detectRefreshRate', () => {
  it('resolves 60 without a window (SSR)', async () => {
    await expect(detectRefreshRate()).resolves.toBe(60)
  })

  it('returns the window override hook without probing', async () => {
    const raf = vi.fn()
    const win = { __qrRefreshRateOverride: 120, requestAnimationFrame: raf } as unknown as QrWindow

    await withWindowMock(win, async () => {
      await expect(detectRefreshRate()).resolves.toBe(120)
    })

    expect(raf).not.toHaveBeenCalled()
  })

  it('probes the browser when no override is set (60 Hz fake)', async () => {
    let t = 0
    const pending: FrameRequestCallback[] = []
    const raf = vi.fn((cb: FrameRequestCallback) => {
      pending.push(cb)
      return pending.length
    })
    const cancel = vi.fn()
    const win = { requestAnimationFrame: raf, cancelAnimationFrame: cancel } as unknown as QrWindow
    const nowSpy = vi.spyOn(performance, 'now').mockImplementation(() => t)

    try {
      await withWindowMock(win, async () => {
        const rate = detectRefreshRate()
        let fired = 0
        while (pending.length > 0 && cancel.mock.calls.length === 0) {
          fired += 1
          t = (fired * 1000) / 60
          const cb = pending.shift()
          cb?.(t)
        }
        await expect(rate).resolves.toBe(60)
        expect(cancel).toHaveBeenCalledTimes(1)
      })
    } finally {
      nowSpy.mockRestore()
    }
  })
})

describe('detectOrientation', () => {
  it('reports portrait when the viewport height exceeds the width', async () => {
    const win = { innerHeight: 2400, innerWidth: 900 } as unknown as QrWindow

    await withWindowMock(win, async () => {
      expect(detectOrientation()).toBe('portrait')
    })
  })

  it('reports landscape when the width meets or exceeds the height', async () => {
    const win = { innerHeight: 900, innerWidth: 2400 } as unknown as QrWindow

    await withWindowMock(win, async () => {
      expect(detectOrientation()).toBe('landscape')
    })
  })

  it('reports landscape for a square viewport', async () => {
    const win = { innerHeight: 1200, innerWidth: 1200 } as unknown as QrWindow

    await withWindowMock(win, async () => {
      expect(detectOrientation()).toBe('landscape')
    })
  })

  it('defaults to landscape without a window (SSR)', () => {
    expect(detectOrientation()).toBe('landscape')
  })
})

describe('transferLabel', () => {
  it.each<[TransferSettings, string]>([
    [{ bytesPerTile: '1k', layout: 'grid4', targetFps: 15, highRefresh: false }, 'V27 · 2×2'],
    [{ bytesPerTile: '2k', layout: 'column3', targetFps: 15, highRefresh: false }, 'V34 · 1×3'],
    [{ bytesPerTile: '2.5k', layout: 'row3', targetFps: 15, highRefresh: false }, 'V40 · 3×1'],
    [{ bytesPerTile: '1k', layout: 'single', targetFps: 15, highRefresh: false }, 'V27 · 1×1'],
  ])('renders %o as %s', (settings, expected) => {
    expect(transferLabel(settings)).toBe(expected)
  })
})

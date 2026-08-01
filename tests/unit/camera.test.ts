import { describe, expect, it } from 'vitest'
import {
  acquireCamera,
  buildConstraints,
  readSettings,
  tryLockFocusExposure,
} from '../../src/receiver/camera'

/**
 * Runs `run` with a stubbed global `navigator`, restoring the original
 * afterwards so tests never leak mocks into one another.
 */
async function withNavigatorMock<T>(mock: Navigator, run: () => Promise<T> | T): Promise<T> {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
  Object.defineProperty(globalThis, 'navigator', { value: mock, configurable: true })
  try {
    return await run()
  } finally {
    if (descriptor === undefined) {
      Reflect.deleteProperty(globalThis, 'navigator')
    } else {
      Object.defineProperty(globalThis, 'navigator', descriptor)
    }
  }
}

describe('buildConstraints', () => {
  it('requests 60 fps as an ideal constraint and the rear camera', () => {
    const constraints = buildConstraints()

    expect(constraints.frameRate).toEqual({ ideal: 60 })
    expect(constraints.facingMode).toBe('environment')
  })

  it('does not put camera-control constraints at the top level', () => {
    const constraints = buildConstraints()

    expect(constraints.focusMode).toBeUndefined()
    expect(constraints.exposureMode).toBeUndefined()
  })

  it('prefers a 1280x720 image', () => {
    const constraints = buildConstraints()

    expect(constraints.width).toEqual({ ideal: 1280 })
    expect(constraints.height).toEqual({ ideal: 720 })
  })

  it('honors a custom preferred fps', () => {
    expect(buildConstraints(30).frameRate).toEqual({ ideal: 30 })
  })

  it('omits the frameRate constraint when the constraint is unsupported', async () => {
    const mockNavigator = {
      mediaDevices: { getSupportedConstraints: () => ({ frameRate: false }) },
    } as unknown as Navigator

    await withNavigatorMock(mockNavigator, () => {
      expect(buildConstraints().frameRate).toBeUndefined()
    })
  })
})

describe('readSettings', () => {
  it('returns the actual video track settings', () => {
    const stream = {
      getVideoTracks: () => [{ getSettings: () => ({ width: 1280, height: 720, frameRate: 30 }) }],
    } as unknown as MediaStream

    expect(readSettings(stream)).toEqual({ width: 1280, height: 720, frameRate: 30 })
  })

  it('returns undefined values when the stream has no video track', () => {
    const stream = { getVideoTracks: () => [] } as unknown as MediaStream

    expect(readSettings(stream)).toEqual({
      width: undefined,
      height: undefined,
      frameRate: undefined,
    })
  })
})

describe('tryLockFocusExposure', () => {
  it('applies continuous focus and exposure constraints', async () => {
    let applied: MediaTrackConstraints | undefined
    const stream = {
      getVideoTracks: () => [
        {
          applyConstraints: (constraints: MediaTrackConstraints) => {
            applied = constraints
            return Promise.resolve()
          },
        },
      ],
    } as unknown as MediaStream

    await tryLockFocusExposure(stream)

    expect(applied).toEqual({
      advanced: [{ focusMode: 'continuous' }, { exposureMode: 'continuous' }],
    })
  })

  it('swallows applyConstraints failures', async () => {
    const stream = {
      getVideoTracks: () => [
        { applyConstraints: () => Promise.reject(new Error('focusMode unsupported')) },
      ],
    } as unknown as MediaStream

    await expect(tryLockFocusExposure(stream)).resolves.toBeUndefined()
  })

  it('is a no-op when the stream has no video track', async () => {
    const stream = { getVideoTracks: () => [] } as unknown as MediaStream

    await expect(tryLockFocusExposure(stream)).resolves.toBeUndefined()
  })
})

describe('acquireCamera', () => {
  it('resolves with the stream and notifies onTrack for every video track', async () => {
    const videoTrack = {} as MediaStreamTrack
    const stream = { getVideoTracks: () => [videoTrack] } as unknown as MediaStream
    const mockNavigator = {
      mediaDevices: { getUserMedia: () => Promise.resolve(stream) },
    } as unknown as Navigator
    let received: MediaStreamTrack | undefined

    const result = await withNavigatorMock(mockNavigator, async () => {
      const acquired = await acquireCamera(buildConstraints(), (track) => {
        received = track
      })
      expect(acquired).toBe(stream)
    })

    expect(result).toBeUndefined()
    expect(received).toBe(videoTrack)
  })

  it.each(['NotAllowedError', 'SecurityError'])('maps %s to a not-allowed error', async (name) => {
    const mockNavigator = {
      mediaDevices: { getUserMedia: () => Promise.reject(new DOMException('denied', name)) },
    } as unknown as Navigator

    await withNavigatorMock(mockNavigator, async () => {
      await expect(acquireCamera(buildConstraints(), () => undefined)).rejects.toMatchObject({
        name: 'CameraError',
        code: 'not-allowed',
      })
    })
  })

  it('maps NotFoundError to a not-found error', async () => {
    const mockNavigator = {
      mediaDevices: {
        getUserMedia: () => Promise.reject(new DOMException('no device', 'NotFoundError')),
      },
    } as unknown as Navigator

    await withNavigatorMock(mockNavigator, async () => {
      await expect(acquireCamera(buildConstraints(), () => undefined)).rejects.toMatchObject({
        name: 'CameraError',
        code: 'not-found',
      })
    })
  })

  it('maps OverconstrainedError to an overconstrained error', async () => {
    const mockNavigator = {
      mediaDevices: {
        getUserMedia: () =>
          Promise.reject(new DOMException('cannot satisfy', 'OverconstrainedError')),
      },
    } as unknown as Navigator

    await withNavigatorMock(mockNavigator, async () => {
      await expect(acquireCamera(buildConstraints(), () => undefined)).rejects.toMatchObject({
        name: 'CameraError',
        code: 'overconstrained',
      })
    })
  })

  it('rejects with a typed error when getUserMedia is unavailable', async () => {
    const mockNavigator = {} as unknown as Navigator

    await withNavigatorMock(mockNavigator, async () => {
      await expect(acquireCamera(buildConstraints(), () => undefined)).rejects.toMatchObject({
        name: 'CameraError',
        code: 'not-supported',
      })
    })
  })

  it('reports insecure-context when mediaDevices is missing on a plain-HTTP page', async () => {
    const mockNavigator = {} as unknown as Navigator
    const realWindow = globalThis.window
    const windowDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'window')
    Object.defineProperty(globalThis, 'window', {
      value: { isSecureContext: false },
      configurable: true,
    })

    try {
      await withNavigatorMock(mockNavigator, async () => {
        await expect(acquireCamera(buildConstraints(), () => undefined)).rejects.toMatchObject({
          name: 'CameraError',
          code: 'insecure-context',
        })
      })
    } finally {
      if (windowDescriptor === undefined) {
        Reflect.deleteProperty(globalThis, 'window')
      } else if (realWindow === undefined) {
        Object.defineProperty(globalThis, 'window', windowDescriptor)
      }
    }
  })
})

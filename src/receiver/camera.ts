/**
 * Browser camera acquisition. Everything touching DOM/WebRTC globals is
 * guarded so the module type-checks and imports cleanly under a Node test
 * runner; the pure helpers (`buildConstraints`, `frameRateConstraintSupported`)
 * are exported so the constraint logic is testable without a camera.
 */

export type CameraErrorCode =
  | 'not-allowed'
  | 'not-found'
  | 'not-readable'
  | 'not-supported'
  | 'insecure-context'
  | 'overconstrained'
  | 'unknown'

/** Typed camera error; `code` lets the UI branch on the failure kind. */
export class CameraError extends Error {
  readonly code: CameraErrorCode

  constructor(code: CameraErrorCode, message: string) {
    super(message)
    this.name = 'CameraError'
    this.code = code
  }
}

/**
 * MediaTrackConstraintSet extended with the camera control constraints that
 * TypeScript's DOM lib does not declare yet (`focusMode` / `exposureMode`).
 */
export interface CameraConstraintSet extends MediaTrackConstraintSet {
  focusMode?: ConstrainDOMString
  exposureMode?: ConstrainDOMString
}

/** {@link MediaTrackConstraints} plus the camera control constraints. */
export interface CameraConstraints extends MediaTrackConstraints {
  focusMode?: ConstrainDOMString
  exposureMode?: ConstrainDOMString
}

/**
 * Whether the browser advertises support for the `frameRate` media constraint.
 * Falls back to "supported" when the environment cannot be probed (e.g. a Node
 * test runner), so the default constraints still request the preferred fps.
 */
export function frameRateConstraintSupported(): boolean {
  if (typeof navigator === 'undefined') {
    return true
  }
  const supported = navigator.mediaDevices?.getSupportedConstraints?.()
  return supported === undefined ? true : supported.frameRate !== false
}

/**
 * Builds the video track constraints for a rear-camera QR scanner.
 *
 * fps is requested as `ideal`, never `exact`: an exact constraint hard-fails
 * the whole getUserMedia call with OverconstrainedError on any camera that
 * cannot deliver the target rate (30 fps-only webcams, many phones), which
 * would make the receiver unusable. The actual delivered rate is read back
 * via {@link readSettings} and used for pacing decisions.
 *
 * `focusMode`/`exposureMode` are deliberately NOT top-level constraints:
 * they are non-standard camera-control constraints, and an unsupported
 * top-level required constraint also rejects with OverconstrainedError. They
 * are applied best-effort afterwards via `advanced` in
 * {@link tryLockFocusExposure}, where failure is swallowed. When the browser
 * does not support the `frameRate` constraint at all, it is omitted.
 */
export function buildConstraints(preferredFps = 60): CameraConstraints {
  const constraints: CameraConstraints = {
    width: { ideal: 1280 },
    height: { ideal: 720 },
    facingMode: 'environment',
  }
  if (frameRateConstraintSupported()) {
    constraints.frameRate = { ideal: preferredFps }
  }
  return constraints
}

/**
 * Wraps `navigator.mediaDevices.getUserMedia`, invoking `onTrack` with every
 * video track of the acquired stream and normalizing failures into typed
 * {@link CameraError}s.
 */
export async function acquireCamera(
  constraints: MediaTrackConstraints,
  onTrack: (track: MediaStreamTrack) => void,
): Promise<MediaStream> {
  if (typeof navigator === 'undefined' || navigator.mediaDevices?.getUserMedia === undefined) {
    // Browsers hide the whole mediaDevices API on insecure origins, so a
    // missing API on a real device almost always means plain-HTTP serving.
    if (
      typeof window !== 'undefined' &&
      typeof window.isSecureContext === 'boolean' &&
      window.isSecureContext === false
    ) {
      throw new CameraError(
        'insecure-context',
        'Camera access requires a secure context (HTTPS or localhost); the page is served over plain HTTP',
      )
    }
    throw new CameraError('not-supported', 'getUserMedia is not available in this environment')
  }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ video: constraints })
    for (const track of stream.getVideoTracks()) {
      onTrack(track)
    }
    return stream
  } catch (error: unknown) {
    throw normalizeGetUserMediaError(error)
  }
}

export interface CameraActualSettings {
  width: number | undefined
  height: number | undefined
  frameRate: number | undefined
}

/**
 * Reads the video track's *actual* settings. This is the iOS-fps-lie
 * mitigation: the requested `exact:60` may resolve to 30, so pacing decisions
 * must use what this returns, never the requested value.
 */
export function readSettings(stream: MediaStream): CameraActualSettings {
  const track = stream.getVideoTracks()[0]
  if (track === undefined) {
    return { width: undefined, height: undefined, frameRate: undefined }
  }
  const settings = track.getSettings()
  return {
    width: settings.width,
    height: settings.height,
    frameRate: settings.frameRate,
  }
}

/**
 * Best-effort lock of continuous autofocus/exposure. Autofocus hunting is the
 * #1 throughput killer for frame-by-frame scanning, so lock both when the
 * device supports it; failures are silently ignored (constraints stay as they
 * were). The optional `videoEl` is reserved for platforms that require the
 * track to be attached to an element before constraints can be applied.
 */
export async function tryLockFocusExposure(
  stream: MediaStream,
  _videoEl?: HTMLVideoElement,
): Promise<void> {
  const track = stream.getVideoTracks()[0]
  if (track === undefined) {
    return
  }
  try {
    const advanced: CameraConstraintSet[] = [
      { focusMode: 'continuous' },
      { exposureMode: 'continuous' },
    ]
    await track.applyConstraints({ advanced })
  } catch {
    // Best-effort only: devices that reject these keep their current behavior.
  }
}

function normalizeGetUserMediaError(error: unknown): CameraError {
  const name = domExceptionName(error)
  switch (name) {
    case 'NotAllowedError':
    case 'SecurityError':
    case 'PermissionDeniedError':
      return new CameraError('not-allowed', 'Camera permission was denied')
    case 'NotFoundError':
    case 'DevicesNotFoundError':
      return new CameraError('not-found', 'No camera device was found')
    case 'OverconstrainedError':
    case 'ConstraintNotSatisfiedError':
      return new CameraError(
        'overconstrained',
        'Camera could not satisfy the requested constraints',
      )
    case 'NotReadableError':
    case 'TrackStartError':
      return new CameraError('not-readable', 'Camera is in use by another application')
    default:
      return new CameraError('unknown', `getUserMedia failed: ${name ?? 'unknown error'}`)
  }
}

function domExceptionName(error: unknown): string | undefined {
  if (error instanceof DOMException) {
    return error.name
  }
  if (typeof error === 'object' && error !== null && 'name' in error) {
    const name = error.name
    if (typeof name === 'string') {
      return name
    }
  }
  return undefined
}

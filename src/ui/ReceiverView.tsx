import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { CameraError } from '../receiver/camera'
import { ReceiverOrchestrator, type ReceiverStats } from '../receiver/orchestrate'
import type { ReassemblyResult } from '../receiver/reassemble'
import { SaveError, saveFile } from '../receiver/save'
import { StatusOverlay } from './StatusOverlay'
import { IconBack, IconCamera, IconRestart, IconSave } from './icons'

interface ReceiverViewProps {
  readonly onExit: () => void
}

type ReceiverPhase = 'idle' | 'starting' | 'scanning' | 'saving' | 'saved' | 'error'

const DECODE_POOL_SIZE = 4

/** Human-facing message for a typed camera failure; unknown errors fall back. */
function cameraErrorMessage(error: unknown): string {
  if (error instanceof CameraError) {
    switch (error.code) {
      case 'not-allowed':
        return 'Camera permission was denied. Allow camera access for this site in your browser settings, then try again.'
      case 'not-found':
        return 'No camera was found on this device.'
      case 'not-readable':
        return 'The camera is in use by another application. Close it and try again.'
      case 'overconstrained':
        return 'The camera could not match the requested settings.'
      case 'not-supported':
        return 'This browser does not support camera scanning.'
      case 'insecure-context':
        return 'Camera access needs HTTPS or localhost. You are opening this page over plain HTTP — serve it via https:// or localhost, then reload.'
      default:
        return error.message
    }
  }
  return error instanceof Error ? error.message : 'Could not start the camera.'
}

export function ReceiverView({ onExit }: ReceiverViewProps) {
  const phase = useSignal<ReceiverPhase>('idle')
  const stats = useSignal<ReceiverStats | undefined>(undefined)
  const result = useSignal<ReassemblyResult | undefined>(undefined)
  const error = useSignal<string | undefined>(undefined)
  const savedName = useSignal<string | undefined>(undefined)
  const videoRef = useRef<HTMLVideoElement>(null)
  const captureRef = useRef<HTMLCanvasElement>(null)
  const orchestratorRef = useRef<ReceiverOrchestrator | undefined>(undefined)

  // Tear down the live orchestrator when leaving the view.
  useEffect(() => {
    return () => {
      stopScan()
    }
  }, [])

  function stopScan() {
    const orchestrator = orchestratorRef.current
    if (orchestrator !== undefined) {
      orchestrator.stop()
      orchestratorRef.current = undefined
    }
  }

  async function startScan(): Promise<void> {
    error.value = undefined
    phase.value = 'starting'
    const video = videoRef.current
    const canvas = captureRef.current
    if (video === null || canvas === null) {
      phase.value = 'error'
      error.value = 'Camera view is not ready. Please try again.'
      return
    }
    try {
      const orchestrator = new ReceiverOrchestrator({
        videoEl: video,
        canvas,
        onStats: (s) => {
          stats.value = s
        },
        onFile: (r) => {
          result.value = r
        },
        poolSize: DECODE_POOL_SIZE,
      })
      orchestratorRef.current = orchestrator
      await orchestrator.start()
      phase.value = 'scanning'
    } catch (err) {
      orchestratorRef.current = undefined
      phase.value = 'error'
      error.value = cameraErrorMessage(err)
    }
  }

  async function restartScan(): Promise<void> {
    stopScan()
    stats.value = undefined
    result.value = undefined
    savedName.value = undefined
    error.value = undefined
    await startScan()
  }

  async function save(): Promise<void> {
    const r = result.value
    if (r === undefined) {
      return
    }
    error.value = undefined
    phase.value = 'saving'
    try {
      const res = await saveFile({ bytes: r.bytes, filename: r.filename, mime: r.mime })
      savedName.value = res.name
      phase.value = 'saved'
    } catch (err) {
      phase.value = 'scanning'
      error.value = err instanceof SaveError ? err.message : 'Saving the file failed.'
    }
  }

  function goBack() {
    stopScan()
    onExit()
  }

  return (
    <div className="view view-receiver">
      <video
        ref={videoRef}
        className="camera-video"
        playsInline
        autoPlay
        muted
        aria-label="Camera preview"
      />
      <canvas ref={captureRef} className="capture-canvas" aria-hidden="true" />

      {phase.value === 'idle' && (
        <section className="receiver-card">
          <div className="brand-mark brand-mark-small">
            <IconCamera />
          </div>
          <h2 className="card-title">Scan a broadcast</h2>
          <p className="card-subtitle">
            Point your camera at the sender's screen to receive a file. Everything happens on device
            — no network required.
          </p>
          <button type="button" className="btn btn-accent btn-lg" onClick={() => void startScan()}>
            Start scanning
          </button>
          <button type="button" className="btn btn-ghost" onClick={goBack}>
            Back
          </button>
        </section>
      )}

      {phase.value === 'starting' && (
        <section className="receiver-card">
          <div className="spinner" role="status" aria-label="Requesting camera" />
          <p className="card-subtitle">Requesting camera…</p>
        </section>
      )}

      {phase.value === 'error' && (
        <section className="receiver-card">
          <p className="error-banner" role="alert">
            {error.value ?? 'Something went wrong.'}
          </p>
          <button type="button" className="btn btn-accent btn-lg" onClick={() => void startScan()}>
            Try again
          </button>
          <button type="button" className="btn btn-ghost" onClick={goBack}>
            Back
          </button>
        </section>
      )}

      {phase.value === 'scanning' && (
        <>
          <div className="receiver-controls">
            <button
              type="button"
              className="btn btn-icon btn-glass"
              onClick={goBack}
              aria-label="Back to home"
            >
              <IconBack />
            </button>
            <button
              type="button"
              className="btn btn-icon btn-glass"
              onClick={() => void restartScan()}
              aria-label="Restart scan"
            >
              <IconRestart />
            </button>
          </div>
          {error.value !== undefined && (
            <p className="error-banner error-banner-overlay" role="alert">
              {error.value}
            </p>
          )}
          <div className="receiver-live">
            {result.value === undefined ? (
              <span className="chip chip-live">SCANNING</span>
            ) : (
              <>
                <span className="badge badge-verified" role="status">
                  ✓ Verified — file complete
                </span>
                <button
                  type="button"
                  className="btn btn-success btn-lg"
                  onClick={() => void save()}
                >
                  <IconSave />
                  <span>Save file</span>
                </button>
              </>
            )}
          </div>
          {stats.value !== undefined && <StatusOverlay stats={stats.value} />}
        </>
      )}

      {phase.value === 'saving' && (
        <section className="receiver-card">
          <div className="spinner" role="status" aria-label="Saving file" />
          <p className="card-subtitle">Saving {result.value?.filename ?? 'file'}…</p>
        </section>
      )}

      {phase.value === 'saved' && (
        <section className="receiver-card">
          <h2 className="card-title">File saved</h2>
          <p className="card-subtitle">
            {savedName.value !== undefined ? (
              <>
                Saved as <strong>{savedName.value}</strong>.
              </>
            ) : (
              'Saved to your device.'
            )}
          </p>
          <button
            type="button"
            className="btn btn-accent btn-lg"
            onClick={() => void restartScan()}
          >
            Scan another
          </button>
          <button type="button" className="btn btn-ghost" onClick={goBack}>
            Back home
          </button>
        </section>
      )}
    </div>
  )
}

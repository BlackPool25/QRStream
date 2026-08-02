import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { SenderDisplay } from '../sender/display'
import { estimateThroughput, type SenderStats } from '../sender/pacing'
import type { PreparedTransfer } from '../sender/pipeline'
import { transferLabel } from '../sender/settings'
import { formatBytes, formatEta } from './format'
import { IconFullscreen, IconMinimize, IconStop } from './icons'

interface SenderBroadcastProps {
  readonly prepared: PreparedTransfer
  /** Navigate back to the home screen after the display has stopped. */
  readonly onStop: () => void
}

/** The live QR broadcast: display canvas, status chips and transport controls. */
export function SenderBroadcast({ prepared, onStop }: SenderBroadcastProps) {
  const stats = useSignal<SenderStats | undefined>(undefined)
  const isFullscreen = useSignal(false)
  const stageRef = useRef<HTMLDivElement>(null)
  const displayRef = useRef<SenderDisplay | undefined>(undefined)

  // Mount the QR display once; tear it down when the broadcast unmounts.
  useEffect(() => {
    const stage = stageRef.current
    if (stage === null) {
      return
    }
    const canvas = document.createElement('canvas')
    canvas.className = 'qr-canvas'
    stage.appendChild(canvas)

    const display = new SenderDisplay({
      canvas,
      prepared,
      settings: prepared.info.settings,
      onStats: (s) => {
        stats.value = s
      },
    })
    display.start()
    displayRef.current = display
    return () => {
      display.dispose()
      canvas.remove()
      displayRef.current = undefined
    }
  }, [prepared])

  // Keep the fullscreen button state in sync with the real document state.
  useEffect(() => {
    const sync = () => {
      isFullscreen.value = document.fullscreenElement !== null
    }
    document.addEventListener('fullscreenchange', sync)
    return () => {
      document.removeEventListener('fullscreenchange', sync)
    }
  }, [])

  function stopBroadcast() {
    const display = displayRef.current
    if (display !== undefined) {
      display.stop()
    }
    onStop()
  }

  async function toggleFullscreen(): Promise<void> {
    const stage = stageRef.current
    if (stage === null) {
      return
    }
    try {
      if (document.fullscreenElement !== null) {
        await document.exitFullscreen()
      } else {
        await stage.requestFullscreen()
      }
    } catch {
      // Fullscreen can be rejected (permission policy); keep the normal layout.
    }
  }

  const s = stats.value
  const elapsedSeconds = s !== undefined && s.fps > 0 ? Math.round(s.tickCount / s.fps) : 0

  return (
    <section className="sender-broadcast">
      <div className="qr-stage" ref={stageRef} />
      <div className="sender-controls">
        <div className="stats-chips" aria-live="polite" aria-label="Broadcast status">
          {s === undefined ? (
            <span className="chip chip-muted">Starting…</span>
          ) : (
            <>
              <span className="chip chip-muted chip-ellipsis" title={prepared.info.filename}>
                {prepared.info.filename}
              </span>
              <span className="chip chip-muted">{formatBytes(prepared.info.totalSize)}</span>
              <span className="chip chip-accent">{transferLabel(prepared.info.settings)}</span>
              {s.fps > 0 && (
                <span className="chip chip-muted" title="Estimated broadcast rate">
                  {formatBytes(estimateThroughput(prepared.info.settings))}/s
                </span>
              )}
              <span className="chip chip-muted">k {s.k}</span>
              <span className="chip chip-muted">{s.fps.toFixed(1)} fps</span>
              <span className="chip chip-warn">{s.droppedTicks} dropped</span>
              <span className="chip chip-muted">{formatEta(elapsedSeconds)}</span>
            </>
          )}
        </div>
        <div className="sender-actions">
          <button
            type="button"
            className="btn btn-ghost"
            onClick={() => void toggleFullscreen()}
            aria-label={isFullscreen.value ? 'Exit fullscreen' : 'Enter fullscreen'}
          >
            {isFullscreen.value ? <IconMinimize /> : <IconFullscreen />}
            <span>Fullscreen</span>
          </button>
          <button
            type="button"
            className="btn btn-danger"
            onClick={stopBroadcast}
            aria-label="Stop broadcast"
          >
            <IconStop />
            <span>Stop</span>
          </button>
        </div>
      </div>
    </section>
  )
}

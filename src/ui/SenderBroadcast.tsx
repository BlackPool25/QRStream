import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { SenderDisplay } from '../sender/display'
import type { SenderStats } from '../sender/pacing'
import type { PreparedTransfer } from '../sender/pipeline'
import { formatBytes, formatEta } from './format'
import { IconFullscreen, IconMinimize, IconStop, IconSun } from './icons'

interface SenderBroadcastProps {
  readonly prepared: PreparedTransfer
  /** Navigate back to the home screen after the display has stopped. */
  readonly onStop: () => void
}

const DEFAULT_FPS = 15

/** The live QR broadcast: display canvas, status chips and transport controls. */
export function SenderBroadcast({ prepared, onStop }: SenderBroadcastProps) {
  const stats = useSignal<SenderStats | undefined>(undefined)
  const boost = useSignal(false)
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
      profile: prepared.info.profile,
      targetFps: DEFAULT_FPS,
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
      // Release the display's own wake lock before stopping the loop.
      if (boost.value) {
        display.setBoost(false)
      }
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

  function toggleBoost() {
    const next = !boost.value
    boost.value = next
    displayRef.current?.setBoost(next)
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
              {/* TEMP: inline label until transferLabel(settings) lands (T10) */}
              <span className="chip chip-accent">
                {s.layout === 'grid4' ? 'GRID 2×2' : 'SINGLE V40'}
              </span>
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
            className="btn btn-ghost"
            onClick={toggleBoost}
            aria-pressed={boost.value}
            aria-label="Toggle boost brightness"
          >
            <IconSun />
            <span>Boost</span>
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

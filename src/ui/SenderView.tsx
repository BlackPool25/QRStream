import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import type { LayoutId, TransferSettings } from '../protocol/constants'
import { suggestLayout } from '../sender/pacing'
import { PipelineError, prepareTransfer, type PreparedTransfer } from '../sender/pipeline'
import { DEFAULT_TRANSFER_SETTINGS, detectRefreshRate } from '../sender/settings'
import { formatBytes } from './format'
import { IconBack } from './icons'
import { SenderBroadcast } from './SenderBroadcast'
import { SenderSettings } from './SenderSettings'

interface SenderViewProps {
  readonly onExit: () => void
}

interface FileMeta {
  readonly name: string
  readonly size: number
}

/** Source bytes + identity the re-prepare path re-feeds to the pipeline. */
interface PreparedSource {
  readonly bytes: Uint8Array
  readonly name: string
  readonly mime: string
}

type SenderPhase = 'pick' | 'preparing' | 'settings' | 'broadcasting'

export function SenderView({ onExit }: SenderViewProps) {
  const phase = useSignal<SenderPhase>('pick')
  const fileMeta = useSignal<FileMeta | undefined>(undefined)
  const prepared = useSignal<PreparedTransfer | undefined>(undefined)
  // Editable settings; bytesPerTile changes re-encode, the rest just re-pace.
  const settings = useSignal<TransferSettings>({ ...DEFAULT_TRANSFER_SETTINGS })
  const refreshRate = useSignal<number | 'detecting'>('detecting')
  const suggestedLayout = useSignal<LayoutId>(DEFAULT_TRANSFER_SETTINGS.layout)
  const error = useSignal<string | undefined>(undefined)
  const dragging = useSignal(false)
  const fileInputRef = useRef<HTMLInputElement>(null)
  // Source bytes kept across the settings phase so a bytesPerTile change can
  // re-run prepareTransfer without re-reading the File.
  const sourceRef = useRef<PreparedSource | undefined>(undefined)
  // Monotonic prepare sequence: a stale prepare (new file or a bytesPerTile
  // change superseded by a newer one) must never overwrite a newer result.
  const prepareToken = useRef(0)

  // A PreparedTransfer owns a live RaptorQ wasm encoder. Dispose it when the
  // view unmounts so transfers abandoned before broadcast (Back / different
  // file) free their encoder; SenderBroadcast.dispose() covers the broadcast
  // path, and encoder.dispose() is idempotent, so the two never double-free.
  useEffect(() => {
    return () => {
      prepared.value?.encoder.dispose()
    }
  }, [])

  async function handleFile(file: File): Promise<void> {
    error.value = undefined
    fileMeta.value = { name: file.name, size: file.size }
    settings.value = { ...DEFAULT_TRANSFER_SETTINGS }
    refreshRate.value = 'detecting'
    suggestedLayout.value = suggestLayout(window.innerWidth, window.innerHeight)
    phase.value = 'preparing'
    // Drop the previous transfer's encoder up front (also covers the case
    // where prepareTransfer below throws and the stale prepared is cleared).
    prepared.value?.encoder.dispose()
    const token = ++prepareToken.current
    try {
      const bytes = new Uint8Array(await file.arrayBuffer())
      sourceRef.current = {
        bytes,
        name: file.name,
        mime: file.type === '' ? 'application/octet-stream' : file.type,
      }
      const result = await prepareTransfer({
        file: sourceRef.current.bytes,
        filename: sourceRef.current.name,
        mime: sourceRef.current.mime,
        settings: DEFAULT_TRANSFER_SETTINGS,
      })
      if (token !== prepareToken.current) return
      prepared.value = result
      const rate = await detectRefreshRate()
      if (token !== prepareToken.current) return
      refreshRate.value = rate
      // Auto-adjust layout + high-refresh to the device. The frames stay valid
      // (bytesPerTile unchanged), so sync info.settings without a re-prepare —
      // the broadcast reads the user's final choice from there.
      const next: TransferSettings = {
        ...DEFAULT_TRANSFER_SETTINGS,
        layout: suggestedLayout.value,
        highRefresh: rate >= 90,
      }
      settings.value = next
      prepared.value = { ...result, info: { ...result.info, settings: next } }
      phase.value = 'settings'
    } catch (err) {
      if (token !== prepareToken.current) return
      prepared.value = undefined
      phase.value = 'pick'
      error.value = err instanceof PipelineError ? err.message : 'Could not prepare the file.'
    }
  }

  /**
   * Re-encode with a new bytesPerTile (new mtu → new k/symbol size). The
   * pipeline only re-runs when the wire format changes; pacing-only settings
   * never reach this path.
   */
  async function rePrepare(next: TransferSettings): Promise<void> {
    const source = sourceRef.current
    if (source === undefined || prepared.value === undefined) {
      return
    }
    prepared.value.encoder.dispose()
    phase.value = 'preparing'
    const token = ++prepareToken.current
    try {
      const result = await prepareTransfer({
        file: source.bytes,
        filename: source.name,
        mime: source.mime,
        settings: next,
      })
      if (token !== prepareToken.current) return
      prepared.value = result
      phase.value = 'settings'
    } catch (err) {
      if (token !== prepareToken.current) return
      prepared.value = undefined
      phase.value = 'pick'
      error.value = err instanceof PipelineError ? err.message : 'Could not prepare the file.'
    }
  }

  function handleSettingsChange(next: TransferSettings): void {
    const bytesPerTileChanged = next.bytesPerTile !== settings.value.bytesPerTile
    settings.value = next
    if (bytesPerTileChanged) {
      void rePrepare(next)
    } else if (prepared.value !== undefined) {
      // Pacing-only change (layout / fps / high-refresh): the prepared frames
      // stay valid, but the broadcast must see the user's choice.
      prepared.value = { ...prepared.value, info: { ...prepared.value.info, settings: next } }
    }
  }

  function pickFile() {
    fileInputRef.current?.click()
  }

  function beginBroadcast() {
    if (prepared.value !== undefined) {
      phase.value = 'broadcasting'
    }
  }

  function backToPick() {
    phase.value = 'pick'
  }

  function onDrop(e: DragEvent) {
    e.preventDefault()
    dragging.value = false
    const file = e.dataTransfer?.files[0]
    if (file !== undefined) {
      void handleFile(file)
    }
  }

  const meta = fileMeta.value

  return (
    <div className="view view-sender">
      <header className="view-header">
        <button type="button" className="btn btn-icon" onClick={onExit} aria-label="Back to home">
          <IconBack />
        </button>
        <span className="view-title">SEND</span>
        <span className="view-header-spacer" aria-hidden="true" />
      </header>

      {phase.value === 'pick' && (
        <section
          className={`card dropzone${dragging.value ? ' dropzone-active' : ''}`}
          onDragOver={(e) => {
            e.preventDefault()
            dragging.value = true
          }}
          onDragLeave={() => {
            dragging.value = false
          }}
          onDrop={onDrop}
        >
          {error.value !== undefined && (
            <p className="error-banner" role="alert">
              {error.value}
            </p>
          )}
          <h2 className="card-title">Send a file</h2>
          <p className="card-subtitle">
            Pick a file to broadcast as a QR stream. No network — the receiver scans your screen.
          </p>
          <button type="button" className="btn btn-accent btn-lg" onClick={pickFile}>
            Choose a file
          </button>
          <p className="dropzone-hint">or drag &amp; drop it anywhere in this box</p>
        </section>
      )}

      {phase.value === 'preparing' && (
        <section className="card card-center">
          <div className="spinner" role="status" aria-label="Preparing transfer" />
          <p className="card-subtitle">
            Preparing {meta?.name ?? 'file'}… (compressing and encoding)
          </p>
        </section>
      )}

      {phase.value === 'settings' && prepared.value !== undefined && (
        <div className="settings-summary">
          <SenderSettings
            settings={settings.value}
            onSettingsChange={handleSettingsChange}
            compressedSize={prepared.value.info.compressedSize}
            refreshRate={refreshRate.value}
            suggestedLayout={suggestedLayout.value}
            onBegin={beginBroadcast}
            onDifferentFile={backToPick}
            fileName={prepared.value.info.filename}
            fileSize={prepared.value.info.totalSize}
          />
          <p className="settings-hint">
            k = {prepared.value.info.k} symbols · mtu {formatBytes(prepared.value.info.mtu)}
          </p>
        </div>
      )}

      {phase.value === 'broadcasting' && prepared.value !== undefined && (
        <SenderBroadcast
          prepared={prepared.value}
          onStop={() => {
            onExit()
          }}
        />
      )}

      <input
        ref={fileInputRef}
        type="file"
        className="visually-hidden"
        onChange={(e) => {
          const file = e.currentTarget.files?.[0]
          e.currentTarget.value = ''
          if (file !== undefined) {
            void handleFile(file)
          }
        }}
      />
    </div>
  )
}

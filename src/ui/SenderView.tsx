import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { PipelineError, prepareTransfer, type PreparedTransfer } from '../sender/pipeline'
import { formatBytes, profileLabel } from './format'
import { IconBack } from './icons'
import { SenderBroadcast } from './SenderBroadcast'

interface SenderViewProps {
  readonly onExit: () => void
}

interface FileMeta {
  readonly name: string
  readonly size: number
}

type SenderPhase = 'pick' | 'preparing' | 'ready' | 'broadcasting'

export function SenderView({ onExit }: SenderViewProps) {
  const phase = useSignal<SenderPhase>('pick')
  const fileMeta = useSignal<FileMeta | undefined>(undefined)
  const prepared = useSignal<PreparedTransfer | undefined>(undefined)
  const error = useSignal<string | undefined>(undefined)
  const dragging = useSignal(false)
  const fileInputRef = useRef<HTMLInputElement>(null)

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
    phase.value = 'preparing'
    // Drop the previous transfer's encoder up front (also covers the case
    // where prepareTransfer below throws and the stale prepared is cleared).
    prepared.value?.encoder.dispose()
    try {
      const bytes = new Uint8Array(await file.arrayBuffer())
      const result = await prepareTransfer({
        file: bytes,
        filename: file.name,
        mime: file.type === '' ? 'application/octet-stream' : file.type,
      })
      prepared.value = result
      phase.value = 'ready'
    } catch (err) {
      prepared.value = undefined
      phase.value = 'pick'
      error.value = err instanceof PipelineError ? err.message : 'Could not prepare the file.'
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

      {phase.value === 'ready' && prepared.value !== undefined && (
        <section className="card card-center">
          <h2 className="card-title">Ready to broadcast</h2>
          <dl className="file-summary">
            <div>
              <dt>File</dt>
              <dd className="file-summary-name">{prepared.value.info.filename}</dd>
            </div>
            <div>
              <dt>Size</dt>
              <dd>{formatBytes(prepared.value.info.totalSize)}</dd>
            </div>
            <div>
              <dt>Profile</dt>
              <dd>{profileLabel(prepared.value.info.profile)}</dd>
            </div>
            <div>
              <dt>Symbols</dt>
              <dd>k = {prepared.value.info.k}</dd>
            </div>
          </dl>
          <div className="card-actions">
            <button type="button" className="btn btn-accent btn-lg" onClick={beginBroadcast}>
              Begin broadcast
            </button>
            <button type="button" className="btn btn-ghost" onClick={() => (phase.value = 'pick')}>
              Different file
            </button>
          </div>
        </section>
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

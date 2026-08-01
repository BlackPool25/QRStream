import {
  BYTES_PER_TILE,
  type BytesPerTileId,
  type LayoutId,
  type TransferSettings,
} from '../protocol/constants'
import { estimateEtaSeconds, estimateThroughput } from '../sender/pacing'
import { transferLabel } from '../sender/settings'
import { formatBytes, formatEta } from './format'
import { IconLandscape, IconPortrait } from './icons'

export interface SenderSettingsProps {
  readonly settings: TransferSettings
  readonly onSettingsChange: (s: TransferSettings) => void
  /** Post-compression payload size (from prepared.info) — drives the ETA. */
  readonly compressedSize: number
  /** Result of detectRefreshRate(); gates the high-refresh toggle. */
  readonly refreshRate: number | 'detecting'
  /** Layout the viewport calls for; shown as "recommended" until overridden. */
  readonly suggestedLayout: LayoutId
  readonly onBegin: () => void
  readonly onDifferentFile: () => void
  readonly fileName: string
  /** Original file size (totalSize) for display. */
  readonly fileSize: number
}

const FPS_OPTIONS: readonly number[] = [12, 15, 24, 30]

const TILE_OPTIONS: ReadonlyArray<{ readonly id: BytesPerTileId; readonly label: string }> = [
  { id: '1k', label: '1 KB' },
  { id: '2k', label: '2 KB' },
  { id: '2.5k', label: '2.5 KB' },
]

const LAYOUT_OPTIONS: ReadonlyArray<{
  readonly id: LayoutId
  readonly label: string
  readonly glyph: 'portrait' | 'landscape' | null
}> = [
  { id: 'single', label: '1×1', glyph: null },
  { id: 'column3', label: '1×3', glyph: 'portrait' },
  { id: 'row3', label: '3×1', glyph: 'landscape' },
  { id: 'grid4', label: '2×2', glyph: null },
  { id: 'grid9', label: '3×3', glyph: null },
]

function formatKilobytesPerSecond(bps: number): string {
  return `~${Math.round(bps / 1024)} KB/s`
}

function formatEtaEstimate(seconds: number): string {
  if (seconds > 0 && seconds < 1) {
    return '~<1s'
  }
  return `~${formatEta(seconds)}`
}

export function SenderSettings(props: SenderSettingsProps) {
  const { settings } = props
  const bps = estimateThroughput(settings)
  const eta = estimateEtaSeconds(settings, props.compressedSize)
  const refreshEnabled = typeof props.refreshRate === 'number' && props.refreshRate >= 90
  const refreshHint =
    props.refreshRate === 'detecting'
      ? 'Detecting display…'
      : `Detected ${props.refreshRate} Hz display`

  return (
    <section className="card settings-panel">
      <header className="settings-header">
        <div className="settings-file">
          <h2 className="settings-file-name" title={props.fileName}>
            {props.fileName}
          </h2>
          <p className="settings-file-size">{formatBytes(props.fileSize)}</p>
        </div>
        <span className="chip chip-accent">{transferLabel(settings)}</span>
      </header>

      <div className="settings-field">
        <span className="settings-label">Display fps</span>
        <div className="segmented" role="radiogroup" aria-label="Display fps">
          {FPS_OPTIONS.map((fps) => {
            const disabled = fps === 30 && !settings.highRefresh
            return (
              <button
                key={fps}
                type="button"
                role="radio"
                aria-checked={settings.targetFps === fps}
                disabled={disabled}
                {...(disabled ? { title: 'Needs a 90 Hz+ display' } : {})}
                className="segmented-option"
                onClick={() => props.onSettingsChange({ ...settings, targetFps: fps })}
              >
                {fps} fps
              </button>
            )
          })}
        </div>
      </div>

      <div className="settings-field">
        <span className="settings-label">Bytes per tile</span>
        <div className="segmented" role="radiogroup" aria-label="Bytes per tile">
          {TILE_OPTIONS.map((option) => {
            const profile = BYTES_PER_TILE[option.id]
            return (
              <button
                key={option.id}
                type="button"
                role="radio"
                aria-checked={settings.bytesPerTile === option.id}
                title={`V${profile.version} · ${profile.frameBudget} B capacity`}
                className="segmented-option"
                onClick={() => props.onSettingsChange({ ...settings, bytesPerTile: option.id })}
              >
                {option.label}
              </button>
            )
          })}
        </div>
      </div>

      <div className="settings-field">
        <span className="settings-label">Tile layout</span>
        <div className="segmented segmented-layout" role="radiogroup" aria-label="Tile layout">
          {LAYOUT_OPTIONS.map((option) => {
            const selected = settings.layout === option.id
            const recommended = selected && props.suggestedLayout === option.id
            return (
              <button
                key={option.id}
                type="button"
                role="radio"
                aria-checked={selected}
                data-layout={option.id}
                data-recommended={recommended ? 'true' : undefined}
                className="segmented-option"
                onClick={() => props.onSettingsChange({ ...settings, layout: option.id })}
              >
                {option.glyph === 'portrait' ? (
                  <IconPortrait size={16} />
                ) : option.glyph === 'landscape' ? (
                  <IconLandscape size={16} />
                ) : null}
                <span>{option.label}</span>
                {recommended && <span className="recommended">recommended</span>}
              </button>
            )
          })}
        </div>
      </div>

      <div className="settings-field settings-field-row">
        <div>
          <span className="settings-label">High refresh rate</span>
          <p className="settings-hint">{refreshHint}</p>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={settings.highRefresh}
          aria-label="High refresh rate"
          disabled={!refreshEnabled}
          className={`switch${settings.highRefresh ? ' switch-on' : ''}`}
          onClick={() =>
            props.onSettingsChange({ ...settings, highRefresh: !settings.highRefresh })
          }
        >
          <span className="switch-thumb" />
        </button>
      </div>

      <div className="settings-field speed-estimate">
        <span className="settings-label">Expected speed</span>
        <p className="speed-value">
          <strong>{formatKilobytesPerSecond(bps)}</strong>
          <span className="speed-sep">·</span>
          <strong>{formatEtaEstimate(eta)}</strong>
        </p>
        <p className="settings-hint">estimate — actual depends on your display</p>
      </div>

      <div className="card-actions">
        <button
          type="button"
          className="btn btn-accent btn-lg"
          name="Begin broadcast"
          onClick={props.onBegin}
        >
          Begin broadcast
        </button>
        <button type="button" className="btn btn-ghost" onClick={props.onDifferentFile}>
          Different file
        </button>
      </div>
    </section>
  )
}

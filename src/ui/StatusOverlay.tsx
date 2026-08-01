import type { ReceiverStats } from '../receiver/orchestrate'

const STATUS_LABELS: Readonly<Record<ReceiverStats['status'], string>> = {
  idle: 'IDLE',
  scanning: 'SCANNING',
  transferring: 'TRANSFERRING',
  complete: 'COMPLETE',
  error: 'ERROR',
}

const OVERLAY_CSS = `
.so-overlay {
  position: fixed;
  left: 12px;
  right: 12px;
  bottom: 12px;
  z-index: 30;
  margin: 0 auto;
  max-width: 560px;
  box-sizing: border-box;
  padding: 12px 14px 14px;
  border-radius: 14px;
  background: rgba(10, 12, 16, 0.85);
  color: #e6e8eb;
  font: 13px/1.4 system-ui, -apple-system, sans-serif;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
  backdrop-filter: blur(6px);
}
.so-top {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.so-chip {
  padding: 2px 10px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.06em;
  background: #1c212b;
  color: #9aa4b2;
}
.so-chip--transferring {
  background: #14324a;
  color: #7dd3fc;
}
.so-chip--complete {
  background: #12301f;
  color: #4ade80;
}
.so-chip--error {
  background: #3a1418;
  color: #fca5a5;
}
.so-badge {
  padding: 3px 10px;
  border-radius: 8px;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.04em;
}
.so-badge--ok {
  background: #12301f;
  color: #4ade80;
  border: 1px solid #22c55e;
}
.so-badge--fail {
  background: #3a1418;
  color: #fca5a5;
  border: 1px solid #ef4444;
}
.so-bar {
  height: 6px;
  margin: 10px 0 8px;
  border-radius: 3px;
  background: #1c212b;
  overflow: hidden;
}
.so-bar-fill {
  height: 100%;
  border-radius: 3px;
  background: linear-gradient(90deg, #3b82f6, #22c55e);
  transition: width 0.3s ease;
}
.so-meta {
  display: flex;
  align-items: baseline;
  gap: 10px;
  justify-content: space-between;
}
.so-count {
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}
.so-filename {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: #9aa4b2;
  max-width: 55%;
}
.so-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 8px;
  margin: 10px 0 0;
}
.so-cell {
  text-align: center;
}
.so-cell dt {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: #9aa4b2;
}
.so-cell dd {
  margin: 2px 0 0;
  font-variant-numeric: tabular-nums;
  font-weight: 600;
  font-size: 13px;
}
.so-dim {
  color: #9aa4b2;
}
`

function formatSpeed(bytesPerSecond: number): string {
  return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`
}

function formatEta(seconds: number | undefined): string {
  if (seconds === undefined) {
    return '—'
  }
  const total = Math.round(Math.max(0, seconds))
  if (total < 60) {
    return `${total}s`
  }
  const minutes = Math.floor(total / 60)
  const rest = total % 60
  return rest === 0 ? `${minutes}m` : `${minutes}m ${rest}s`
}

export function StatusOverlay({ stats }: { readonly stats: ReceiverStats }) {
  const progressPercent = Math.round(Math.min(1, Math.max(0, stats.progress)) * 100)
  return (
    <aside className="so-overlay" aria-label="Transfer status">
      <style>{OVERLAY_CSS}</style>
      <div className="so-top">
        <span className={`so-chip so-chip--${stats.status}`}>{STATUS_LABELS[stats.status]}</span>
        {stats.verified === true && (
          <span className="so-badge so-badge--ok" role="status">
            ✓ VERIFIED (SHA-256)
          </span>
        )}
        {stats.verified === false && (
          <span className="so-badge so-badge--fail" role="status">
            HASH MISMATCH
          </span>
        )}
      </div>
      <div
        className="so-bar"
        role="progressbar"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={progressPercent}
      >
        <div className="so-bar-fill" style={{ width: `${progressPercent}%` }} />
      </div>
      <div className="so-meta">
        <span className="so-count">
          {stats.unique} / {stats.k ?? '…'}
        </span>
        {stats.fileName !== undefined && (
          <span className="so-filename" title={stats.fileName}>
            {stats.fileName}
          </span>
        )}
      </div>
      <dl className="so-grid">
        <div className="so-cell">
          <dt>Decode</dt>
          <dd>{stats.decodeRate.toFixed(1)} fps</dd>
        </div>
        <div className="so-cell">
          <dt>Speed</dt>
          <dd>{formatSpeed(stats.bytesPerSecond)}</dd>
        </div>
        <div className="so-cell">
          <dt>ETA</dt>
          <dd>{formatEta(stats.etaSeconds)}</dd>
        </div>
        <div className="so-cell">
          <dt>Dropped</dt>
          <dd className="so-dim">{stats.droppedCount}</dd>
        </div>
      </dl>
    </aside>
  )
}

import type { ProfileId } from '../sender/pipeline'

const BYTE_UNITS = ['KB', 'MB', 'GB', 'TB'] as const

/**
 * Human-readable byte size: '900 B', '1.5 MB', '3 GB'. Below 100 the value
 * keeps one decimal; 100 and above round to a whole number.
 */
export function formatBytes(n: number): string {
  if (n < 1024) {
    return `${n} B`
  }
  let value = n
  let unitIndex = -1
  do {
    value /= 1024
    unitIndex += 1
  } while (value >= 1024 && unitIndex < BYTE_UNITS.length - 1)
  const unit = BYTE_UNITS[unitIndex] ?? 'TB'
  const formatted = value >= 100 ? Math.round(value) : Math.round(value * 10) / 10
  return `${formatted} ${unit}`
}

/**
 * Human-readable duration from seconds: '12s', '3m 20s', '1h 5m'. Non-finite
 * or negative inputs clamp to '0s'.
 */
export function formatEta(seconds: number): string {
  const total = Number.isFinite(seconds) ? Math.round(Math.max(0, seconds)) : 0
  if (total < 60) {
    return `${total}s`
  }
  const minutes = Math.floor(total / 60)
  const restSeconds = total % 60
  if (minutes < 60) {
    return restSeconds === 0 ? `${minutes}m` : `${minutes}m ${restSeconds}s`
  }
  const hours = Math.floor(minutes / 60)
  const restMinutes = minutes % 60
  return restMinutes === 0 ? `${hours}h` : `${hours}h ${restMinutes}m`
}

const PROFILE_LABELS: Readonly<Record<ProfileId, string>> = {
  grid: 'GRID 2×2',
  v40: 'SINGLE V40',
}

/** Human label for a transfer profile id. */
export function profileLabel(profile: ProfileId): string {
  return PROFILE_LABELS[profile]
}

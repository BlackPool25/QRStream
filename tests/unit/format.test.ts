import { describe, expect, it } from 'vitest'
import { formatBytes, formatEta, profileLabel } from '../../src/ui/format'

describe('formatBytes', () => {
  it('renders raw bytes below 1 KiB with the B unit', () => {
    expect(formatBytes(0)).toBe('0 B')
    expect(formatBytes(900)).toBe('900 B')
  })

  it('renders KiB/MiB/GiB with one decimal below 100', () => {
    expect(formatBytes(1024)).toBe('1 KB')
    expect(formatBytes(1536)).toBe('1.5 KB')
    expect(formatBytes(1024 * 1024)).toBe('1 MB')
    expect(formatBytes(1.5 * 1024 * 1024)).toBe('1.5 MB')
    expect(formatBytes(3 * 1024 * 1024 * 1024)).toBe('3 GB')
  })

  it('rounds to whole numbers at 100 or larger', () => {
    expect(formatBytes(100 * 1024 * 1024)).toBe('100 MB')
    expect(formatBytes(5 * 1024 * 1024 * 1024 * 1024)).toBe('5 TB')
  })
})

describe('formatEta', () => {
  it('renders seconds below a minute', () => {
    expect(formatEta(0)).toBe('0s')
    expect(formatEta(12)).toBe('12s')
    expect(formatEta(59)).toBe('59s')
  })

  it('renders minutes with a seconds remainder', () => {
    expect(formatEta(60)).toBe('1m')
    expect(formatEta(200)).toBe('3m 20s')
  })

  it('renders hours with a minutes remainder', () => {
    expect(formatEta(3600)).toBe('1h')
    expect(formatEta(3660)).toBe('1h 1m')
    expect(formatEta(7325)).toBe('2h 2m')
  })

  it('clamps negative or fractional inputs to whole seconds', () => {
    expect(formatEta(-5)).toBe('0s')
    expect(formatEta(12.9)).toBe('13s')
  })
})

describe('profileLabel', () => {
  it('maps the grid profile to its human label', () => {
    expect(profileLabel('grid')).toBe('GRID 2×2')
  })

  it('maps the v40 profile to its human label', () => {
    expect(profileLabel('v40')).toBe('SINGLE V40')
  })
})

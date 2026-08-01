import { describe, expect, it } from 'vitest'
import {
  GRID_MAX_FPS,
  GRID_MIN_CANVAS_PX,
  MIN_FPS,
  V40_MAX_FPS,
  adaptFps,
  chooseProfile,
  computeFrameDelayMs,
  nextEsiRoundRobin,
  renderBudgetOk,
} from '../../src/sender/pacing'
import { computePxPerModule, recommendDistance } from '../../src/sender/controls'

describe('computeFrameDelayMs', () => {
  it('rounds 1000/fps to the nearest millisecond', () => {
    expect(computeFrameDelayMs(24)).toBe(42) // 1000/24 = 41.67
    expect(computeFrameDelayMs(12)).toBe(83) // 1000/12 = 83.33
    expect(computeFrameDelayMs(60)).toBe(17) // 1000/60 = 16.67
  })
})

describe('chooseProfile', () => {
  it('selects the 2x2 grid on canvases at least GRID_MIN_CANVAS_PX', () => {
    const choice = chooseProfile(24, GRID_MIN_CANVAS_PX)

    expect(choice.profile).toBe('grid')
    expect(choice.tilesPerFrame).toBe(4)
    expect(choice.maxFramesPerSecond).toBe(GRID_MAX_FPS)
  })

  it('selects the single-V40 profile on smaller canvases', () => {
    const choice = chooseProfile(12, 800)

    expect(choice.profile).toBe('v40')
    expect(choice.tilesPerFrame).toBe(1)
    expect(choice.maxFramesPerSecond).toBe(V40_MAX_FPS)
  })

  it('caps the frame rate at the profile maximum when the target is higher', () => {
    expect(chooseProfile(60, GRID_MIN_CANVAS_PX).maxFramesPerSecond).toBe(GRID_MAX_FPS)
    expect(chooseProfile(60, 800).maxFramesPerSecond).toBe(V40_MAX_FPS)
  })

  it('never exceeds the requested target fps', () => {
    expect(chooseProfile(10, GRID_MIN_CANVAS_PX).maxFramesPerSecond).toBe(10)
  })
})

describe('renderBudgetOk', () => {
  it('passes when encode+render fits the frame delay with the default 1.5x margin', () => {
    expect(renderBudgetOk(20, 42)).toBe(true) // 20*1.5 = 30 <= 42
    expect(renderBudgetOk(30, 42)).toBe(false) // 30*1.5 = 45 > 42
  })

  it('honors a custom overhead factor', () => {
    expect(renderBudgetOk(20, 42, 2)).toBe(true) // 40 <= 42
    expect(renderBudgetOk(22, 42, 2)).toBe(false) // 44 > 42
  })

  it('passes at the exact boundary', () => {
    expect(renderBudgetOk(28, 42)).toBe(true) // 42 <= 42
  })
})

describe('adaptFps', () => {
  it('keeps the current fps while the work fits the frame budget', () => {
    expect(adaptFps(24, 20, 42)).toBe(24)
  })

  it('steps down by 4 when over budget, floored at MIN_FPS', () => {
    expect(adaptFps(24, 30, 42)).toBe(20)
    expect(adaptFps(MIN_FPS, 30, 42)).toBe(MIN_FPS)
  })
})

describe('nextEsiRoundRobin', () => {
  it('is deterministic: the same frameIndex yields the same esis', () => {
    expect(nextEsiRoundRobin(8, 4, 3, 2)).toEqual(nextEsiRoundRobin(8, 4, 3, 2))
  })

  it('shows tilesPerFrame distinct packets within one frame', () => {
    const esis = nextEsiRoundRobin(8, 4, 1, 2)

    expect(esis).toHaveLength(2)
    expect(new Set(esis).size).toBe(2)
  })

  it('cycles source esi 0..k-1 first, then wraps into the repair range', () => {
    expect(nextEsiRoundRobin(4, 4, 0, 2)).toEqual([0, 1])
    expect(nextEsiRoundRobin(4, 4, 2, 2)).toEqual([4, 5]) // repair range starts at k
  })

  it('wraps around the whole pool back to source', () => {
    expect(nextEsiRoundRobin(4, 4, 7, 2)).toEqual([6, 7])
    expect(nextEsiRoundRobin(4, 4, 8, 2)).toEqual([0, 1])
  })

  it('never returns esi outside [0, k + repairAvailable)', () => {
    const k = 3
    const repairAvailable = 2
    for (let frameIndex = 0; frameIndex < 50; frameIndex++) {
      for (const esi of nextEsiRoundRobin(k, repairAvailable, frameIndex, 2)) {
        expect(esi).toBeGreaterThanOrEqual(0)
        expect(esi).toBeLessThan(k + repairAvailable)
      }
    }
  })

  it('handles a zero repair pool', () => {
    expect(nextEsiRoundRobin(3, 0, 5, 1)).toEqual([2]) // 5 % 3 = 2
  })
})

describe('computePxPerModule', () => {
  it('is integerScalePx over the full module count including the quiet zone', () => {
    // V27: 27*4+17 = 125 modules + 2*4 quiet = 133 total
    expect(computePxPerModule(800, 27)).toBe(6) // floor(800/133)
    // V40: 40*4+17 = 177 modules + 2*4 quiet = 185 total
    expect(computePxPerModule(1080, 40)).toBe(5) // floor(1080/185)
  })

  it('honors a custom quiet zone', () => {
    expect(computePxPerModule(800, 27, 0)).toBe(6) // floor(800/125)
    expect(computePxPerModule(530, 27, 0)).toBe(4) // floor(530/125)
  })
})

describe('recommendDistance', () => {
  it('produces the canonical guidance for 4 px/module', () => {
    expect(recommendDistance(4)).toBe('hold ~40-70cm away')
  })

  it('recommends farther distances for larger modules', () => {
    expect(recommendDistance(2)).toBe('hold ~15-45cm away')
    expect(recommendDistance(12)).toBe('hold ~155-185cm away')
  })
})

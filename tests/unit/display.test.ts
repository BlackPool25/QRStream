import { describe, expect, it } from 'vitest'
import {
  MIN_FPS,
  adaptFps,
  computeFrameDelayMs,
  computeLayoutGeometry,
  estimateEtaSeconds,
  estimateThroughput,
  nextEsiRoundRobin,
  renderBudgetOk,
  resolvePacing,
  suggestLayout,
} from '../../src/sender/pacing'
import { computePxPerModule, recommendDistance } from '../../src/sender/controls'

describe('computeFrameDelayMs', () => {
  it('rounds 1000/fps to the nearest millisecond', () => {
    expect(computeFrameDelayMs(24)).toBe(42) // 1000/24 = 41.67
    expect(computeFrameDelayMs(12)).toBe(83) // 1000/12 = 83.33
    expect(computeFrameDelayMs(60)).toBe(17) // 1000/60 = 16.67
  })
})

describe('suggestLayout', () => {
  it('maps portrait canvases to column3', () => {
    expect(suggestLayout(900, 2400)).toBe('column3')
  })

  it('maps landscape canvases to row3', () => {
    expect(suggestLayout(2400, 900)).toBe('row3')
  })

  it('picks grid9 only on square-ish canvases with both sides >= GRID9_MIN_CANVAS_PX', () => {
    expect(suggestLayout(2000, 2000)).toBe('grid9')
    expect(suggestLayout(1600, 1600)).toBe('grid4') // < 1800
  })

  it('picks grid4 on square-ish canvases >= GRID4_MIN_CANVAS_PX', () => {
    expect(suggestLayout(1600, 1600)).toBe('grid4')
    expect(suggestLayout(800, 1000)).toBe('grid4') // exact 0.8 aspect -> size branch
  })

  it('falls back to single below GRID4_MIN_CANVAS_PX', () => {
    expect(suggestLayout(600, 600)).toBe('single')
    expect(suggestLayout(500, 400)).toBe('single') // exact 1.25 aspect -> size branch
  })

  it('honors the 0.8 / 1.25 aspect boundaries exactly', () => {
    expect(suggestLayout(790, 1000)).toBe('column3') // 0.79 < 0.8
    expect(suggestLayout(800, 1000)).toBe('grid4') // 0.8 exact -> size branch
    expect(suggestLayout(1250, 1000)).toBe('grid4') // 1.25 exact -> size branch
    expect(suggestLayout(1260, 1000)).toBe('row3') // 1.26 > 1.25
  })
})

describe('resolvePacing', () => {
  it('applies the 24fps display-refresh ceiling to a 30fps layout cap', () => {
    const pacing = resolvePacing(
      { bytesPerTile: '1k', layout: 'grid4', targetFps: 15, highRefresh: false },
      1600,
      1600,
    )

    expect(pacing.tilesPerFrame).toBe(4)
    expect(pacing.fpsCeiling).toBe(24) // layoutCap 30, refreshCap 24
    expect(pacing.effectiveFps).toBe(15)
    expect(pacing.suggestedLayout).toBe('grid4')
  })

  it('clamps a high target to the fpsCeiling', () => {
    expect(
      resolvePacing(
        { bytesPerTile: '1k', layout: 'grid4', targetFps: 30, highRefresh: false },
        1600,
        1600,
      ).effectiveFps,
    ).toBe(24)
  })

  it('raises the ceiling to 30 on high-refresh displays', () => {
    expect(
      resolvePacing(
        { bytesPerTile: '1k', layout: 'grid4', targetFps: 30, highRefresh: true },
        1600,
        1600,
      ).effectiveFps,
    ).toBe(30)
  })

  it('caps grid9 at its own 24fps layout limit even on high-refresh displays', () => {
    expect(
      resolvePacing(
        { bytesPerTile: '1k', layout: 'grid9', targetFps: 30, highRefresh: true },
        1600,
        1600,
      ).fpsCeiling,
    ).toBe(24)
  })

  it('never exceeds the requested target fps', () => {
    expect(
      resolvePacing(
        { bytesPerTile: '1k', layout: 'single', targetFps: 12, highRefresh: false },
        600,
        600,
      ).effectiveFps,
    ).toBe(12)
  })
})

describe('computeLayoutGeometry', () => {
  it('splits a grid4 canvas into 2x2 cells with an integer ppm', () => {
    const g = computeLayoutGeometry(1600, 1600, 'grid4', 27)

    expect(g.cellW).toBe(800)
    expect(g.cellH).toBe(800)
    expect(g.ppm).toBe(6) // integerScalePx(27*4+17+8=133, 800)
  })

  it('splits a portrait column3 canvas into 1x3 cells', () => {
    const g = computeLayoutGeometry(900, 2400, 'column3', 27)

    expect(g.cellW).toBe(900)
    expect(g.cellH).toBe(800)
    expect(g.ppm).toBe(6) // min cell side 800
  })

  it('splits a landscape row3 canvas into 3x1 cells', () => {
    const g = computeLayoutGeometry(2400, 900, 'row3', 27)

    expect(g.cellW).toBe(800)
    expect(g.cellH).toBe(900)
    expect(g.ppm).toBe(6) // min cell side 800
  })

  it('uses the larger V40 module count for the ppm', () => {
    const g = computeLayoutGeometry(600, 600, 'single', 40)

    expect(g.cellW).toBe(600)
    expect(g.cellH).toBe(600)
    expect(g.ppm).toBe(3) // integerScalePx(40*4+17+8=185, 600)
  })

  it('honors a custom quiet zone', () => {
    expect(computeLayoutGeometry(1600, 1600, 'grid4', 27, 0).ppm).toBe(6) // integerScalePx(125, 800)
  })
})

describe('estimateThroughput', () => {
  it('default 1k grid4 at 15fps: 15 x (4 - 1/32) x 1024 B/s', () => {
    expect(
      estimateThroughput({
        bytesPerTile: '1k',
        layout: 'grid4',
        targetFps: 15,
        highRefresh: false,
      }),
    ).toBe(60960)
  })

  it('2k grid4 at 24fps: 24 x (4 - 1/32) x 2048 B/s', () => {
    expect(
      estimateThroughput({
        bytesPerTile: '2k',
        layout: 'grid4',
        targetFps: 24,
        highRefresh: false,
      }),
    ).toBe(195072)
  })

  it('2.5k row3 at 30fps on high refresh: 30 x (3 - 1/32) x 2560 B/s', () => {
    expect(
      estimateThroughput({
        bytesPerTile: '2.5k',
        layout: 'row3',
        targetFps: 30,
        highRefresh: true,
      }),
    ).toBe(228000)
  })

  it('single layout carries one data tile per tick minus the metadata slot', () => {
    expect(
      estimateThroughput({
        bytesPerTile: '2.5k',
        layout: 'single',
        targetFps: 30,
        highRefresh: true,
      }),
    ).toBe(
      74400, // 30 x (1 - 1/32) x 2560
    )
  })
})

describe('estimateEtaSeconds', () => {
  it('reports ~17.2s for a 1 MiB file at the default 60,960 B/s', () => {
    expect(
      estimateEtaSeconds(
        { bytesPerTile: '1k', layout: 'grid4', targetFps: 15, highRefresh: false },
        1048576,
      ),
    ).toBeCloseTo(17.2, 1)
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

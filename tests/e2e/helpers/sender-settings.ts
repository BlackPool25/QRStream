import { expect, type Page } from '@playwright/test'

/**
 * Sender settings-phase driver (S2). The send flow now sits between file-pick
 * and broadcast: a settings panel whose controls (segmented radio buttons for
 * bytes-per-tile / layout / fps, a high-refresh switch, "Begin broadcast")
 * the e2e drives against the REAL markup (role="radio" buttons, data-layout
 * buttons) so a settings choice provably reaches the broadcast.
 */

/** Settings overrides an e2e may apply on the panel before beginning. */
export interface SenderSettingsOverride {
  readonly bytesPerTile?: '1k' | '2k' | '2.5k'
  readonly layout?: 'single' | 'column3' | 'row3' | 'grid4' | 'grid9'
  readonly fps?: 12 | 15 | 24 | 30
  readonly highRefresh?: boolean
}

declare global {
  interface Window {
    /** Test hook: detectRefreshRate() returns this instead of probing rAF. */
    __qrRefreshRateOverride?: number
  }
}

/** The panel is ready (and interactive) once "Begin broadcast" is visible. */
export async function waitForSettingsPanel(page: Page, timeout = 15_000): Promise<void> {
  await expect(page.getByRole('button', { name: 'Begin broadcast' })).toBeVisible({ timeout })
}

/**
 * Applies `overrides` to the settings panel. A bytesPerTile change re-encodes
 * (the phase flips back through 'preparing'), so the panel is re-waited before
 * later overrides are applied. highRefresh is applied before fps so a 30 fps
 * choice is clickable once the switch is on.
 */
export async function applySenderSettings(
  page: Page,
  overrides: Partial<SenderSettingsOverride>,
): Promise<void> {
  if (overrides.bytesPerTile !== undefined) {
    const label = { '1k': '1 KB', '2k': '2 KB', '2.5k': '2.5 KB' }[overrides.bytesPerTile]
    await page
      .getByRole('radiogroup', { name: 'Bytes per tile' })
      .getByRole('radio', { name: label, exact: true })
      .click()
    await waitForSettingsPanel(page)
  }
  if (overrides.layout !== undefined) {
    await page
      .getByRole('radiogroup', { name: 'Tile layout' })
      .locator(`[data-layout="${overrides.layout}"]`)
      .click()
  }
  if (overrides.highRefresh !== undefined) {
    const sw = page.getByRole('switch', { name: 'High refresh rate' })
    const on = (await sw.getAttribute('aria-checked')) === 'true'
    if (on !== overrides.highRefresh) {
      await sw.click()
    }
  }
  if (overrides.fps !== undefined) {
    await page
      .getByRole('radiogroup', { name: 'Display fps' })
      .getByRole('radio', { name: `${overrides.fps} fps`, exact: true })
      .click()
  }
}

/** Clicks "Begin broadcast" to leave the settings phase and start the loop. */
export async function clickBeginBroadcast(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Begin broadcast' }).click()
}

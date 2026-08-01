import { expect, test, type Page } from '@playwright/test'

/**
 * Offline PWA verification against the production build:
 *   1. first (online) load registers + activates the service worker,
 *   2. the precache contains BOTH codec wasm modules (zxing reader + raptorq),
 *   3. after the network goes away, reloading the SPA still serves the app
 *      from the service worker (navigateFallback -> precached index.html).
 *
 * The app title text doubles as the offline-reload assertion: with the network
 * gone, the only way the document renders at all is via the SW's precache.
 */
const WASM_ASSETS = [
  { filename: 'zxing_reader', label: 'zxing reader' },
  { filename: 'raptorq_bg', label: 'raptorq' },
] as const

const hasWasm = (url: string, filename: string) => url.includes(filename) && url.endsWith('.wasm')

test('service worker precaches both wasm modules and serves the app offline', async ({
  context,
  page,
}) => {
  // Given a first load while online
  await page.goto('/')
  await page.evaluate(() => navigator.serviceWorker.ready)
  await expect(page).toHaveTitle('QR Data Transfer')

  // Then the SW registration is active and the page is under its control
  const registration = await page.evaluate(async () => {
    const reg = await navigator.serviceWorker.getRegistration()
    return reg === undefined
      ? null
      : {
          scope: reg.scope,
          state: reg.active?.state ?? null,
          controller: Boolean(navigator.serviceWorker.controller),
        }
  })
  expect(registration).not.toBeNull()
  expect(registration?.scope).toBe('http://127.0.0.1:4173/')
  expect(registration?.state).toBe('activated')
  expect(registration?.controller).toBe(true)

  // And both wasm modules are in the precache (poll: precache fills during install)
  const cachedUrls = await waitForPrecachedWasm(page)
  for (const { filename, label } of WASM_ASSETS) {
    expect(
      cachedUrls.some((url) => hasWasm(url, filename)),
      `precache manifest contains ${label} wasm`,
    ).toBe(true)
  }
  console.log('[pwa-offline] cached URLs:\n' + cachedUrls.map((url) => `  ${url}`).join('\n'))

  // When the network disappears and the page reloads
  await context.setOffline(true)
  await page.reload({ waitUntil: 'domcontentloaded' })

  // Then the app still renders — served from the SW's precache
  await expect(page.getByText('QR Data Transfer')).toBeVisible()
  await expect(page.getByText('scaffold OK')).toBeVisible()

  await context.setOffline(false)
})

/** Polls every CacheStorage cache until both wasm URLs are present. */
async function waitForPrecachedWasm(page: Page): Promise<string[]> {
  let urls: string[] = []
  await expect
    .poll(
      async () => {
        urls = await page.evaluate(async () => {
          const found: string[] = []
          for (const name of await window.caches.keys()) {
            const cache = await window.caches.open(name)
            for (const request of await cache.keys()) {
              found.push(request.url)
            }
          }
          return found
        })
        return WASM_ASSETS.every(({ filename }) => urls.some((url) => hasWasm(url, filename)))
      },
      { timeout: 15_000 },
    )
    .toBe(true)
  return urls
}

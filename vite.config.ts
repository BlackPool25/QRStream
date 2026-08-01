/// <reference types="vitest/config" />
import { defineConfig } from 'vitest/config'
import preact from '@preact/preset-vite'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    preact(),
    VitePWA({
      // Decision: 'autoUpdate' over 'prompt' — the app holds no local state worth
      // protecting across a SW update, so a custom update-prompt UI is ceremony.
      // The generated SW skipWaiting() + clientsClaim()s and takes over on reload.
      registerType: 'autoUpdate',
      // Plugin injects <script src="/registerSW.js"> into index.html (default
      // 'auto'); no manual registration in main.tsx needed.
      injectRegister: 'auto',
      // Icons are precached by the workbox glob below; disable the plugin's own
      // manifest-icon addition to avoid duplicate entries in the SW manifest.
      includeManifestIcons: false,
      manifest: {
        name: 'QR Data Transfer',
        short_name: 'QR Transfer',
        description:
          'Offline-first QR file-transfer PWA — broadcast files phone-to-phone with zero network',
        theme_color: '#0f1115',
        background_color: '#0f1115',
        display: 'standalone',
        start_url: '/',
        scope: '/',
        icons: [
          // Hand-authored PNGs (scripts/make-icons.mjs) under public/. Chrome
          // installability needs a 192x192 + 512x512 PNG; maskable is for masks.
          { src: '/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
          { src: '/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
          {
            src: '/icon-maskable-512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
        ],
      },
      workbox: {
        // The two codec wasm modules (~1.02 MiB zxing_reader + ~235 KiB raptorq)
        // MUST be precached for zero-network operation after first load; Vite
        // emits them as hashed dist/assets via the `?url` imports in
        // src/wasm-assets.ts. Default glob already covers wasm; extended here to
        // also sweep the PNG/SVG icons and the web manifest.
        globPatterns: ['**/*.{js,css,html,wasm,png,svg}'],
        // Default 2 MiB per-file cap; zxing_reader.wasm is ~1.02 MiB on its own.
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
        // SPA, hash-free routing: offline navigations must fall back to the
        // precached index.html (resolves identically to the plugin default).
        navigateFallback: '/index.html',
        // No runtimeCaching: every fetchable asset is already precached.
      },
    }),
  ],
  test: {
    environment: 'node',
    include: ['tests/unit/**/*.test.ts', 'src/**/*.test.ts', 'tests/soak/**/*.test.ts'],
  },
})

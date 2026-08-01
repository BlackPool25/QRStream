import { defineConfig } from '@playwright/test'

// E2E against the production build: `vite preview` serves dist/ on the Vite
// default preview port. Run `npm run build` before `npx playwright test`.
export default defineConfig({
  testDir: 'tests/e2e',
  fullyParallel: true,
  reporter: 'list',
  use: {
    baseURL: 'http://127.0.0.1:4173',
  },
  webServer: {
    // --host pins IPv4: vite preview otherwise binds to IPv6 localhost only.
    command: 'npm run preview -- --port 4173 --strictPort --host 127.0.0.1',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
})

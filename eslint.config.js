// @ts-check
import js from '@eslint/js'
import tseslint from 'typescript-eslint'
import globals from 'globals'

export default tseslint.config(
  {
    ignores: [
      'dist',
      'coverage',
      'dev-dist',
      'node_modules',
      '.playwright',
      '.omo',
      '.codegraph',
      '.archive',
      'flutter_app/build',
      'flutter_app/.dart_tool',
      'flutter_app/rust/target',
      '*.local',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: {
        ...globals.browser,
      },
    },
    rules: {
      // In Preact (automatic JSX runtime) JSX never leaves an unused
      // in-scope variable, so react/jsx-uses-vars has no equivalent needed.
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      // type-only triple-slash refs are the canonical vitest config pattern.
      '@typescript-eslint/triple-slash-reference': ['error', { types: 'always' }],
    },
  },
  {
    files: ['vite.config.ts', 'playwright.config.ts', 'eslint.config.js'],
    languageOptions: {
      globals: {
        ...globals.node,
      },
    },
  },
  {
    files: ['scripts/**/*.mjs'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: {
        ...globals.node,
        // scripts/ may drive a browser via Playwright and run page.evaluate
        // code that references DOM globals (document/window/HTMLCanvasElement).
        ...globals.browser,
      },
    },
  },
)

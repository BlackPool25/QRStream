/**
 * Soak-test report writer.
 *
 * The soak suite's only external artifact: a TSV table of every matrix cell
 * (size, payload, model, result, overhead ratio, elapsed). The suite rewrites
 * it on every run — regenerate with `npm run soak` (default, <=1MB) or
 * `SOAK_FULL=1 npm run soak` (full, incl. the 10MB cases).
 */

import { appendFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

export const REPORT_PATH = fileURLToPath(new URL('./soak-report.txt', import.meta.url))

export function initReport(mode: 'default' | 'full'): void {
  const lines = [
    'soak-report.txt — QR Data Transfer loss-model soak matrix',
    '================================================================',
    `generated : ${new Date().toISOString()}`,
    `mode      : ${mode}`,
    'command   : npm run soak                  (default, sizes <= 1MB)',
    '            SOAK_FULL=1 npm run soak      (full, incl. the 10MB ceiling)',
    'regenerate: the suite overwrites this file on every run.',
    '',
    'size\tpayload\tmodel\tresult\toverhead(distinct/k)\ttotalFed\telapsedMs',
  ]
  writeFileSync(REPORT_PATH, lines.join('\n') + '\n')
}

/** Appends one TSV row; single appendFileSync call keeps rows atomic. */
export function reportRow(row: string): void {
  appendFileSync(REPORT_PATH, row + '\n')
}

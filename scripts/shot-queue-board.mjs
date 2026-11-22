#!/usr/bin/env node
/* Verify the Bed Ready print board: QC column relabelled "Inspect", Delivered column
 * hidden, and screenshot it. */
import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';
import { _electron as electron } from 'playwright-core';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'br-q-'));

function assert(label, cond) { if (!cond) throw new Error(`ASSERT FAILED: ${label}`); console.log(`  ✓ ${label}`); }

async function main() {
  const app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`], cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_FLAVOR: 'bedready' }, timeout: 120_000,
  });
  const w = await app.firstWindow();
  const errs = [];
  w.on('pageerror', (e) => errs.push(String(e && e.message || e)));
  await w.waitForSelector('.khayt-app', { timeout: 60_000 });
  await w.waitForFunction(() => typeof window.switchTab === 'function'
    && typeof window.renderMachineQueues === 'function'
    && typeof window.renderKanban === 'function', { timeout: 60_000 });
  await w.evaluate(() => window.switchTab('queue-tab'));
  await w.waitForSelector('.kanban-col[data-status="qc"]', { timeout: 8000 });
  await w.waitForTimeout(300);

  const board = await w.evaluate(() => {
    const qc = document.querySelector('.kanban-col[data-status="qc"] h3')?.textContent || '';
    const delCol = document.querySelector('.kanban-col[data-status="delivered"]');
    const delVisible = delCol ? getComputedStyle(delCol).display !== 'none' : false;
    const cols = Array.from(document.querySelectorAll('.kanban-col')).filter((c) => getComputedStyle(c).display !== 'none')
      .map((c) => (c.querySelector('h3 span[data-i18n]')?.textContent || '').trim());
    return { qc, delVisible, cols };
  });
  assert(`QC column relabelled "Inspect" (got "${board.qc.replace(/\d+.*$/, '').trim()}")`, /Inspect/.test(board.qc));
  assert('Delivered column hidden', board.delVisible === false);
  assert(`visible columns: ${board.cols.join(', ')}`, !board.cols.includes('Delivered'));

  await w.screenshot({ path: path.join(root, 'scratch-queue-board.png') });
  console.log('  screenshot → scratch-queue-board.png');
  assert('no renderer errors', errs.length === 0);
  if (errs.length) console.log(errs);
  await app.close();
  console.log('\nOK — board verified.');
}
main().catch((e) => { console.error(e); process.exit(1); });

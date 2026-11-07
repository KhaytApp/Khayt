#!/usr/bin/env node
/**
 * E2E: Library Health and Find Similar on the desktop library.
 *
 * The rules are unit-tested (test/library-health.test.js,
 * test/library-similar.test.js). What only a running app can show is the
 * wiring: the disk is asked through hub:printlib-list (stubbed here — the
 * real one reads userData, and a missing file is the case under test), the
 * groups reach the panel with the right counts, Show puts a group on the
 * grid, and Find Similar narrows the grid to a model's geometric twin and
 * leaves an unrelated model out. Every press is a real click.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const KEY = '1000:5000:40x30x20';

function rec(id, name, o = {}) {
  return {
    id, name, originalName: id + '.stl', createdAt: Date.now(), updatedAt: Date.now(),
    sourceFile: { filename: id + '.stl', originalName: id + '.stl', size: 1000, ext: 'stl', kind: 'model' },
    parsed: { printTimeMins: 60, filamentGrams: 20 }, colors: [], tags: ['e2e'], folder: '',
    thumb: 'thumb' in o ? o.thumb : PNG, contentHash: o.hash || ('hash-' + id),
    geometryKey: 'key' in o ? o.key : null, group: o.group || '',
  };
}

async function stubDisk() {
  await electronApp.evaluate(({ ipcMain }) => {
    ipcMain.removeHandler('hub:printlib-list');
    // Every model's file is on disk except E2E-MISS's.
    ipcMain.handle('hub:printlib-list', async (_e, id) => (id === 'E2E-MISS'
      ? []
      : [{ filename: id + '.stl', fullPath: '/nonexistent/' + id + '.stl', size: 1000, tiered: false }]));
    ipcMain.removeHandler('hub:printlib-status');
    ipcMain.handle('hub:printlib-status', async () => ({ ok: true, reason: 'ok', root: '/nonexistent' }));
  });
}

async function seed(window) {
  await window.evaluate(([records]) => {
    printFiles.length = 0;
    for (const r of records) printFiles.push(r);
    renderPrintFiles();
  }, [[
    rec('E2E-MISS', 'Lost bracket', { key: '500:900:10x10x10' }),
    rec('E2E-NOPIC', 'Plain hook', { thumb: null, key: '600:800:12x12x12' }),
    rec('E2E-LEFT', 'Arm left', { key: KEY, group: 'Robots' }),
    rec('E2E-RIGHT', 'Arm right', { key: KEY, group: 'Robots' }),
    rec('E2E-GEAR', 'Gear', { key: '20:3:300x2x1', group: 'Parts' }),
  ]]);
}

const shownIds = (window) => window.evaluate(() =>
  [...document.querySelectorAll('#pfList .pf-card')].map((c) => c.dataset.id));

async function testHealthCounts(window) {
  await window.click('[data-act="pf-health"]');
  await window.waitForSelector('#pfHealth .pf-hg[data-kind="missing"]');
  const groups = await window.evaluate(() => Object.fromEntries(
    [...document.querySelectorAll('#pfHealth .pf-hg')].map((s) => [s.dataset.kind, {
      n: s.querySelector('.pf-hg-n')?.textContent.trim(),
      ids: [...s.querySelectorAll('.pf-hg-list li[data-id]')].map((li) => li.dataset.id),
    }])));
  if (!groups.missing || groups.missing.n !== '1' || groups.missing.ids.join() !== 'E2E-MISS') {
    throw new Error('missing group wrong: ' + JSON.stringify(groups.missing));
  }
  if (!groups.noPicture || groups.noPicture.n !== '1' || groups.noPicture.ids.join() !== 'E2E-NOPIC') {
    throw new Error('no-picture group wrong: ' + JSON.stringify(groups.noPicture));
  }
  // The mirrored pair is a look, never a duplicate.
  if (!groups.looksSame || groups.looksSame.n !== '2') throw new Error('looks-same group wrong: ' + JSON.stringify(groups.looksSame));
  if (groups.sameFile) throw new Error('different bytes were called the same file');
  const title = await window.textContent('#pfHealth .pf-hg[data-kind="missing"] .pf-hg-title');
  if (!/computer/i.test(title || '') || /\bMac\b/.test(title || '')) throw new Error('the desktop should not say "Mac": ' + title);

  // Show in Library puts exactly that group on the grid.
  await window.click('[data-act="pf-health-show"][data-kind="missing"]');
  await window.waitForSelector('#pfFocusChip');
  const ids = await shownIds(window);
  if (ids.join() !== 'E2E-MISS') throw new Error('Show in Library showed ' + ids.join());
  await window.click('[data-act="pf-focus-clear"]');
  await window.waitForSelector('#pfFocusChip', { state: 'detached' });
  if ((await shownIds(window)).length !== 5) throw new Error('clearing the focus did not bring the library back');
}

async function testFindSimilar(window) {
  await window.click('.pf-card[data-id="E2E-LEFT"] details.ovf > summary');
  await window.click('.pf-card[data-id="E2E-LEFT"] [data-act="pf-similar"]');
  await window.waitForSelector('#pfFocusChip');
  const ids = await shownIds(window);
  if (ids[0] !== 'E2E-LEFT') throw new Error('the model asked about should lead: ' + ids.join());
  if (!ids.includes('E2E-RIGHT')) throw new Error('its geometric twin was not found: ' + ids.join());
  if (ids.includes('E2E-GEAR')) throw new Error('an unrelated model was offered as similar: ' + ids.join());
  const note = await window.evaluate(() => document.querySelector('.pf-focus-note')?.textContent || '');
  if (!/mirror/i.test(note)) throw new Error('a same-shape match must carry the mirror caveat: ' + note);
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(60_000);
  await dismissWizard(window);
  await stubDisk();
  await switchTab(window, 'printfiles-tab');
  await seed(window);

  await testHealthCounts(window);
  await testFindSimilar(window);

  console.log('e2e-library-health: ok (missing + no-picture counted, Show focuses, Find Similar finds the twin and not the gear)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

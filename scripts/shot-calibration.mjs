#!/usr/bin/env node
/* Boots Bed Ready, opens the Calibration Assistant, screenshots it, and validates
 * the procedurally-generated ASCII STL for every test/material combo. */
import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';
import { _electron as electron } from 'playwright-core';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'br-cal-'));

function assert(label, cond) { if (!cond) throw new Error(`ASSERT FAILED: ${label}`); console.log(`  ✓ ${label}`); }

async function main() {
  const app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_FLAVOR: 'bedready' },
    timeout: 120_000,
  });
  const w = await app.firstWindow();
  const errs = [];
  w.on('pageerror', (e) => errs.push(String(e && e.message || e)));
  await w.waitForSelector('.khayt-app', { timeout: 60_000 });
  await w.waitForFunction(() => typeof window.hubAPI?.loadStore === 'function'
    && typeof window.renderPrintFiles === 'function'
    && typeof window.openCalibration === 'function', { timeout: 60_000 });

  await w.evaluate(() => (window.switchTab || window.KhaytShell?.switchTab)('printfiles-tab'));
  await w.waitForSelector('.pf-head', { timeout: 8000 });
  const hasBtn = await w.evaluate(() => !!document.querySelector('[data-act="pf-calibrate"]'));
  assert('Calibrate button present in Print Files (BR)', hasBtn);

  await w.evaluate(() => document.querySelector('[data-act="pf-calibrate"]').click());
  await w.waitForSelector('.cal-wrap', { timeout: 8000 });
  await w.waitForTimeout(300);
  assert('modal shows test detail', await w.evaluate(() => !!document.querySelector('.cal-steps li')));

  const shot = path.join(root, 'scratch-calibration.png');
  await w.screenshot({ path: shot });
  console.log('  screenshot →', shot);

  // Validate the generated STL for each test × a few materials
  const tests = await w.evaluate(() => Object.keys(window.KhaytCalibration.TESTS));
  const mats = ['PLA', 'PETG', 'TPU'];
  for (const test of tests) {
    for (const mat of mats) {
      const stl = await w.evaluate(({ test, mat }) =>
        window.KhaytCalibration._buildModel(window.KhaytCalibration.TESTS[test].model, mat), { test, mat });
      const name = stl.split(/\s/)[1];
      const facets = (stl.match(/facet normal/g) || []).length;
      const verts = (stl.match(/vertex /g) || []).length;
      assert(`${test}/${mat}: valid STL (${facets} facets)`,
        stl.startsWith('solid ') && stl.trim().endsWith('endsolid ' + name)
        && facets >= 12 && verts === facets * 3 && !/NaN|undefined/.test(stl));
    }
  }

  // Log a result and confirm it persists into the log view
  await w.evaluate(() => {
    document.querySelector('#calResult').value = '205 °C';
    document.querySelector('#calSave').click();
  });
  await w.waitForTimeout(200);
  assert('result logged to list', await w.evaluate(() => !!document.querySelector('.cal-log-val')));
  assert('result persisted to settings.calibrationLog',
    await w.evaluate(() => Array.isArray(settings.calibrationLog) && settings.calibrationLog.length >= 1));

  assert('no renderer errors', errs.length === 0);
  if (errs.length) console.log(errs);
  await app.close();
  console.log('\nOK — calibration assistant verified.');
}
main().catch((e) => { console.error(e); process.exit(1); });

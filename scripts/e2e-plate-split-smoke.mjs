#!/usr/bin/env node
/**
 * E2E: "Split into plates" and "keep the prime tower" in the real desktop converter.
 *
 * Node tests cover lib/plate-split.js, the worker job and the wiring's source. This drives
 * what they cannot: the converter opened on a three-plate project in a real window, the
 * split checkbox (off until ticked), Convert going through hub:mf-split-plates and the
 * utilityProcess worker, and three files landing in the chosen folder. The folder dialog
 * is stubbed in the main process to answer with a folder of our own.
 *
 *   node scripts/e2e-plate-split-smoke.mjs
 */
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { createRequire } from 'node:module';
import { launchApp, makeUserDataDir, dismissWizard, root } from './e2e/helpers.mjs';

const require = createRequire(import.meta.url);
const { buildMultiPlate3mf } = require(path.join(root, 'test', 'helpers', 'multi-plate-3mf.js'));
const mf = require(path.join(root, 'lib', 'mf-convert.js'));

const userData = makeUserDataDir();
const src = path.join(userData, 'poster.3mf');
const outDir = path.join(userData, 'split-out');
fs.writeFileSync(src, buildMultiPlate3mf());
fs.mkdirSync(outDir);
// A file already there under plate 1's name must survive: the split numbers its own copy.
fs.writeFileSync(path.join(outDir, 'poster-plate1.3mf'), 'keep me');

const fail = (m) => { throw new Error(m); };
const tmpSplitDirs0 = fs.readdirSync(os.tmpdir()).filter((d) => d.startsWith('khayt-split-'));
let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  await electronApp.evaluate(({ dialog }, dir) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [dir] });
  }, outDir);

  await window.evaluate((p) => window.openConverter({ path: p, name: 'poster.3mf' }), src);
  await window.waitForSelector('#convTarget', { timeout: 30_000 });
  await window.selectOption('#convTarget', 'snapmaker-u1');
  await window.dispatchEvent('#convTarget', 'change');

  // The split choice appears once the plates are listed; it starts unticked.
  await window.waitForSelector('#convSplitOn', { timeout: 30_000 });
  if (await window.isChecked('#convSplitOn')) fail('split is on before the maker ticks it');
  // The fixture carries variable layer height and the U1 is a Snapmaker: the tower choice shows, unticked.
  await window.waitForSelector('#convKeepTower', { timeout: 10_000 });
  if (await window.isChecked('#convKeepTower')) fail('keep-tower is on before the maker ticks it');

  await window.click('#convSplitOn');
  await window.click('#convKeepTower');
  const hidden = await window.evaluate(() => getComputedStyle(document.querySelector('.conv-dest')).display === 'none');
  if (!hidden) fail('the whole-file destination is still shown while splitting');

  await window.click('[data-act="save"]');
  const deadline = Date.now() + 60_000;
  let files = [];
  while (Date.now() < deadline) {
    files = fs.readdirSync(outDir).filter((f) => f !== 'poster-plate1.3mf').sort();
    if (files.length >= 3) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  const want = ['poster-plate1-2.3mf', 'poster-plate2.3mf', 'poster-plate3.3mf'];
  if (JSON.stringify(files) !== JSON.stringify(want)) fail(`folder holds ${JSON.stringify(files)}, wanted ${JSON.stringify(want)}`);
  if (fs.readFileSync(path.join(outDir, 'poster-plate1.3mf'), 'utf8') !== 'keep me') fail('an existing file was overwritten');

  for (const f of want) {
    const buf = fs.readFileSync(path.join(outDir, f));
    const a = mf.analyze(buf);
    if (!a.ok || !a.hasGeometry) fail(`${f} is not a readable 3MF`);
    // keep-prime-tower drops the VLH profile from every plate.
    if (a.variableLayerHeight && mf.readMembers(buf).some((m) => /layer_heights_profile\.txt$/i.test(m.name))) {
      fail(`${f} still carries layer_heights_profile.txt with keep-prime-tower ticked`);
    }
  }
  const tmpBefore = new Set(tmpSplitDirs0);
  const leftover = fs.readdirSync(os.tmpdir()).filter((d) => d.startsWith('khayt-split-') && !tmpBefore.has(d));
  if (leftover.length) fail(`the split left its temp folder behind: ${leftover.join(', ')}`);
  console.log(`✔ split into ${want.length} files in the chosen folder; existing file kept; VLH dropped for the tower; temp folder cleared`);
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

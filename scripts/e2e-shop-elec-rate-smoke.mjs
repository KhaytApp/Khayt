#!/usr/bin/env node
/**
 * E2E: the shop's own electricity price (settings.elecRate).
 *
 * Settings › Business takes it, the calculator follows it, a blank removes it
 * and the calculator goes back to Khayt's 0.18.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;
const calcRate = (w) => w.evaluate(() => Number(document.getElementById('elecRate').value));
async function setShopRate(w, v) {
  await w.evaluate((val) => {
    document.getElementById('set_elecRate').value = val;
    saveSettingsFromForm();
  }, v);
}

try {
  ({ electronApp } = await launchApp(userData));
  const w = await electronApp.firstWindow();
  w.setDefaultTimeout(120_000);
  await dismissWizard(w);
  if (await calcRate(w) !== 0.18) throw new Error(`a fresh shop should open on 0.18, got ${await calcRate(w)}`);

  await setShopRate(w, '0.32');
  let s = await w.evaluate(() => settings.elecRate);
  if (s !== 0.32) throw new Error(`the field did not save as a number: ${JSON.stringify(s)}`);
  if (await calcRate(w) !== 0.32) throw new Error(`the calculator did not follow the shop price: ${await calcRate(w)}`);

  // A price typed into the calculator is the shop's business; it stays.
  await w.evaluate(() => { document.getElementById('elecRate').value = '0.5'; });
  await setShopRate(w, '0.4');
  if (await calcRate(w) !== 0.5) throw new Error(`a typed calculator price was overwritten: ${await calcRate(w)}`);

  // Blank removes the key.
  await w.evaluate(() => { document.getElementById('elecRate').value = '0.4'; });
  await setShopRate(w, '');
  s = await w.evaluate(() => ('elecRate' in settings));
  if (s) throw new Error('a blank field should remove settings.elecRate');
  if (await calcRate(w) !== 0.18) throw new Error(`with no shop price the calculator should fall back to 0.18: ${await calcRate(w)}`);
  console.log('e2e-shop-elec-rate: ok (saved as a number, calculator follows, typed value kept, blank removes)');
} catch (e) {
  console.error('e2e-shop-elec-rate: FAIL', e && e.stack || e);
  process.exitCode = 1;
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch {}
}

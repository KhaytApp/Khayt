#!/usr/bin/env node
/**
 * E2E: a print file remembers which settings worked.
 *
 * The rules are unit-tested. What only a running app can show is the flow a shop
 * actually uses: open a file's setups, add one, log how it went, and see the
 * recommendation appear on the card. It also exercises a modal opened from
 * inside another modal — the shared #modalMount is emptied on every open, which
 * has bitten this codebase before.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

const FILE_ID = 'E2E-PF-1';

async function seedPrintFile(window) {
  await window.evaluate((id) => {
    if (!Array.isArray(window.printFiles)) printFiles = [];
    printFiles.length = 0;
    printFiles.unshift({
      id, name: 'E2E Bracket', originalName: 'bracket.3mf',
      createdAt: Date.now(), updatedAt: Date.now(),
      sourceFile: { filename: 'bracket.3mf', originalName: 'bracket.3mf', ext: '3mf', kind: 'model' },
      parsed: {}, colors: [], tags: [], folder: '', material: '', favorite: false,
    });
    if (!machines.some((m) => m.id === 'E2E-M1')) machines.push({ id: 'E2E-M1', name: 'E2E Printer' });
    renderPrintFiles();
  }, FILE_ID);
  // Present, not visible: Setups lives in the card's overflow menu now, which
  // is a closed <details>. Waiting for it to be VISIBLE would wait for ever.
  await window.waitForSelector(`[data-act="pf-setups"][data-id="${FILE_ID}"]`, { state: 'attached' });
}

/**
 * Open a card's overflow, the way a shop does.
 *
 * Most of what a print file can do moved behind one "More actions" control, so
 * a script that clicks straight through to the button is no longer driving the
 * screen — it is reaching past it. Playwright says so plainly: the locator
 * resolves to a HIDDEN element and the wait times out, which is what caught
 * this change rather than any assertion here.
 */
async function openCardMenu(window, id) {
  const opened = await window.evaluate((fileId) => {
    const btn = document.querySelector(`[data-act="pf-setups"][data-id="${fileId}"]`);
    const menu = btn && btn.closest('details.ovf');
    if (!menu) return false;        // an older layout with the actions in the row
    menu.setAttribute('open', '');
    return true;
  }, id);
  if (opened) await window.waitForSelector(`[data-act="pf-setups"][data-id="${id}"]`, { state: 'visible' });
}

// closest() takes the NEAREST matching ancestor, so a selector list containing
// "div" matches the actions wrapper rather than the card. Ask for the card.
const cardText = (window) => window.evaluate((id) => {
  const card = document.querySelector(`.pf-card[data-id="${id}"]`)
    || document.querySelector(`[data-act="pf-setups"][data-id="${id}"]`)?.closest('.pf-card');
  return card?.textContent || '';
}, FILE_ID);

/** Add a setup through the real dialogs, as a shop would. */
async function addSetup(window, { name, layer, nozzle, material }) {
  await openCardMenu(window, FILE_ID);
  await window.click(`[data-act="pf-setups"][data-id="${FILE_ID}"]`);
  await window.waitForSelector('[data-sact="add"]');
  await window.click('[data-sact="add"]');
  // A modal opened from inside a modal — the mount is shared and gets emptied.
  await window.waitForSelector('#suName');
  await window.fill('#suName', name);
  await window.fill('#suLayer', String(layer));
  await window.fill('#suNozzle', String(nozzle));
  await window.fill('#suMaterial', material);
  await window.selectOption('#suMachine', 'E2E-M1');
  await window.click('[data-act="save"]');
  // …and the list it came from must come back, not the bare grid.
  await window.waitForSelector('[data-sact="add"]');
}

async function closeModal(window) {
  await window.evaluate(() => document.querySelector('[data-act="cancel"]')?.click());
  await window.waitForSelector('[data-sact="add"]', { state: 'detached' }).catch(() => {});
}

async function testAddingASetupSurvivesTheNestedModal(window) {
  await addSetup(window, { name: 'Draft', layer: 0.28, nozzle: 0.4, material: 'PLA' });
  const stored = await window.evaluate((id) =>
    JSON.parse(JSON.stringify((printFiles.find((f) => f.id === id) || {}).setups || [])), FILE_ID);
  if (stored.length !== 1) throw new Error(`expected 1 setup, got ${stored.length}`);
  if (stored[0].name !== 'Draft') throw new Error(`name was ${stored[0].name}`);
  if (stored[0].layerHeightMm !== 0.28) throw new Error(`layer was ${stored[0].layerHeightMm}`);
  if (stored[0].machineId !== 'E2E-M1') throw new Error(`machine was ${stored[0].machineId}`);
  await closeModal(window);
}

async function testUntriedSetupIsNotSoldAsProven(window) {
  const text = await cardText(window);
  if (!/Needs testing/i.test(text)) {
    throw new Error(`a setup nobody has run should read as needing testing: ${text.slice(0, 300)}`);
  }
  if (/Known good/i.test(text)) throw new Error('an untried setup was labelled known good');
}

async function testLoggingPrintsMakesItKnownGood(window) {
  await openCardMenu(window, FILE_ID);
  await window.click(`[data-act="pf-setups"][data-id="${FILE_ID}"]`);
  await window.waitForSelector('[data-sact="ok"]');
  for (let i = 0; i < 3; i++) {
    await window.click('[data-sact="ok"]');
    await window.waitForTimeout(50);
  }
  const s = await window.evaluate((id) =>
    JSON.parse(JSON.stringify(printFiles.find((f) => f.id === id).setups[0])), FILE_ID);
  if (s.ok !== 3) throw new Error(`expected 3 successes, got ${s.ok}`);
  if (!s.lastOkAt) throw new Error('no timestamp was recorded');
  await closeModal(window);

  const text = await cardText(window);
  if (!/Known good/i.test(text)) {
    throw new Error(`three clean prints should read as known good: ${text.slice(0, 300)}`);
  }
  if (!/PLA/.test(text) || !/E2E Printer/.test(text)) {
    throw new Error(`the card does not say WHICH settings worked: ${text.slice(0, 300)}`);
  }
}

async function testTheReliableSetupIsRecommended(window) {
  // A second setup that fails more often than it works must not displace the
  // proven one just by being used more.
  await addSetup(window, { name: 'Fast', layer: 0.32, nozzle: 0.6, material: 'PETG' });
  await window.evaluate((id) => {
    const f = printFiles.find((x) => x.id === id);
    const fast = f.setups.find((s) => s.name === 'Fast');
    fast.ok = 5; fast.failed = 5; fast.lastOkAt = new Date().toISOString();
    saveAll(); renderPrintFiles();
  }, FILE_ID);
  await closeModal(window);

  const text = await cardText(window);
  if (/PETG/.test(text)) {
    throw new Error(`a 50%% setup was recommended over a reliable one: ${text.slice(0, 300)}`);
  }
  if (!/PLA/.test(text)) throw new Error(`the reliable setup is no longer recommended: ${text.slice(0, 300)}`);
}

async function testAllFailedSaysSo(window) {
  await window.evaluate((id) => {
    const f = printFiles.find((x) => x.id === id);
    f.setups.forEach((s) => { s.ok = 0; s.failed = 3; s.status = null; });
    saveAll(); renderPrintFiles();
  }, FILE_ID);
  const text = await cardText(window);
  if (!/No setup has worked/i.test(text)) {
    throw new Error(`with every setup failing the card must say so: ${text.slice(0, 300)}`);
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'printfiles-tab');
  await seedPrintFile(window);

  await testAddingASetupSurvivesTheNestedModal(window);
  await testUntriedSetupIsNotSoldAsProven(window);
  await testLoggingPrintsMakesItKnownGood(window);
  await testTheReliableSetupIsRecommended(window);
  await testAllFailedSaysSo(window);

  console.log('e2e-print-setups: ok (nested modal, untried, known good, reliable wins, all failed)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

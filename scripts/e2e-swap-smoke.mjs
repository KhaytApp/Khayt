#!/usr/bin/env node
/**
 * E2E: "Group by colour" in Suggested assignments (lib/swap-queue.js).
 *
 * One single-head printer and four waiting jobs that alternate red and blue.
 * In the scheduler's order every job needs a spool change; grouped by colour,
 * two of them do not. The window offers the grouping with the saving, ticking
 * it reorders the rows and the per-row changes, and Apply still assigns the
 * printer only.
 *
 *   node scripts/e2e-swap-smoke.mjs
 */
import { launchApp, makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';
import fs from 'node:fs';

const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  await window.evaluate(() => {
    machines.splice(0, machines.length, { id: 'M-one', name: 'One head', color: '#38a', maxColors: 1, loaded: [] });
    const job = (id, hex) => ({ id, project: id, date: localDateStr(), status: 'queued', printTime: 1,
      parts: [{ colour: hex, material: 'PLA', grams: 10, qty: 1 }] });
    printLog.push(job('J1-red', '#ff0000'), job('J2-blue', '#0000ff'), job('J3-red', '#ff0000'), job('J4-blue', '#0000ff'));
    settings.swapMinutes = 5;
    saveAll();
    openScheduleSuggestions();
  });

  await window.waitForSelector('#schedGroupColour', { timeout: 10_000 });
  const saves = await window.$eval('#schedSwap label', (el) => el.textContent.replace(/\s+/g, ' '));
  if (!/2/.test(saves) || !/10 min/.test(saves)) fail(`saving line is "${saves}", wanted 2 changes (~10 min)`);

  const rows = () => window.$$eval('#schedRows tr', (trs) => trs.map((tr) => ({
    id: tr.dataset.oid, adds: tr.querySelector('.swap-adds').textContent.trim() })));
  const before = await rows();
  const added = (list) => list.filter((r) => r.adds).length;
  if (added(before) !== 4) fail(`scheduler order shows ${added(before)} jobs adding a change, wanted 4: ${JSON.stringify(before)}`);

  await window.click('#schedGroupColour');
  const after = await rows();
  const colours = after.map((r) => r.id.split('-')[1]).join(',');
  if (!/^(red,red,blue,blue|blue,blue,red,red)$/.test(colours)) fail(`grouped order is ${colours}`);
  if (added(after) !== 2) fail(`grouped order shows ${added(after)} jobs adding a change, wanted 2`);

  await window.click('#schedGroupColour');
  if (JSON.stringify(await rows()) !== JSON.stringify(before)) fail('unticking did not restore the scheduler order');

  // Apply assigns the printer, as before.
  await window.click('.modal-footer [data-act="save"]');
  await window.waitForFunction(() => printLog.filter((o) => /^J\d/.test(o.id) && o.machineId === 'M-one').length === 4, null, { timeout: 5_000 });

  console.log('swap smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}

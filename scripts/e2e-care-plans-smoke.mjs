#!/usr/bin/env node
/**
 * E2E: care plans, "Not needed" and "Parts to buy" in the real desktop window.
 *
 * test/care-plans.test.js covers lib/care-plans.js and test/care-plans-desktop.test.js
 * the wiring's source. This drives what neither can: the machine's maintenance window
 * opening on the plan its record matches, Apply adding the plan's tasks and (only when
 * ticked) taking the plan's interval for a task the shop already had, "Not needed" on
 * a task that is due, and the buy list listing the part of an overdue task.
 *
 *   node scripts/e2e-care-plans-smoke.mjs
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

  // A Bambu X1 with one task of its own: the nozzle, every 300 h (the plan says 500).
  await window.evaluate(() => {
    machines.push({ id: 'MACH-e2e-x1', name: 'Shop X1', vendor: 'Bambu Lab', printerModelName: 'Bambu Lab X1 Carbon', kind: 'fdm', status: 'active' });
    machMaintTasks.push({ id: 'MTASK-e2e-nozzle', machineId: 'MACH-e2e-x1', name: t('maint.t_nozzle'),
      intervalHours: 300, intervalDays: null, lastDoneHours: 0, lastDoneAt: new Date().toISOString() });
    openMaintLog('MACH-e2e-x1');
  });

  await window.click('#btnCarePlan');
  await window.waitForSelector('#cpPlan', { timeout: 10_000 });
  const picked = await window.evaluate(() => [document.querySelector('#cpBrand').value, document.querySelector('#cpPlan').value]);
  if (picked[0] !== 'Bambu Lab' || picked[1] !== 'bambu-x1') fail(`picker opened on ${picked.join(' / ')}, wanted Bambu Lab / bambu-x1`);
  const adds = await window.$$eval('#cpAddList li', (li) => li.length);
  if (adds !== 8) fail(`preview lists ${adds} tasks to add, wanted 8 (the nozzle is already there)`);
  if (await window.isChecked('#cpUsePlan')) fail('"use the plan\'s intervals" is on before the shop ticks it');
  await window.click('#cpUsePlan');
  await window.click('[data-act="cp-apply"]');

  const after = await window.evaluate(() => machMaintTasks.filter((x) => x.machineId === 'MACH-e2e-x1')
    .map((x) => ({ id: x.id, careTaskId: x.careTaskId, h: x.intervalHours, carePlanId: x.carePlanId })));
  if (after.length !== 9) fail(`machine has ${after.length} tasks after Apply, wanted 9`);
  const nozzle = after.find((x) => x.id === 'MTASK-e2e-nozzle');
  if (!nozzle || nozzle.careTaskId !== 'nozzle' || nozzle.h !== 500) fail(`the shop's nozzle task was not linked and moved to 500 h: ${JSON.stringify(nozzle)}`);
  if (after.some((x) => x.carePlanId !== 'bambu-x1')) fail('a task is not linked to the plan');
  const rows = await window.$$eval('#maintTasksList tr', (tr) => tr.length);
  if (rows !== 9) fail(`task list shows ${rows} rows, wanted 9`);

  // Age the carbon filter past its 90 days: it is due, offers "Not needed", and its
  // part is on the buy list as "order now".
  await window.evaluate(() => {
    const tk = machMaintTasks.find((x) => x.machineId === 'MACH-e2e-x1' && x.careTaskId === 'filter');
    tk.lastDoneAt = new Date(Date.now() - 100 * 86400000).toISOString();
    document.querySelector('[data-act="cancel"]').click();
  });
  await window.evaluate(() => {
    document.querySelectorAll('.modal-backdrop').forEach((m) => m.remove());
    window.openPartsToBuy();
  });
  await window.waitForSelector('#pbTable tr[data-part="carbon_filter"]', { timeout: 10_000 });
  const late = await window.$eval('#pbTable tr[data-part="carbon_filter"]', (tr) => tr.textContent);
  const lateWord = await window.evaluate(() => t('maint.pb_late'));
  if (!late.includes(lateWord)) fail(`the overdue filter row does not say "${lateWord}": ${late.trim()}`);
  await window.evaluate(() => document.querySelectorAll('.modal-backdrop').forEach((m) => m.remove()));

  await window.evaluate(() => openMaintLog('MACH-e2e-x1'));
  const filterId = await window.evaluate(() => machMaintTasks.find((x) => x.careTaskId === 'filter').id);
  await window.waitForSelector(`[data-act="mt-defer"][data-id="${filterId}"]`, { timeout: 10_000 });
  const logBefore = await window.evaluate(() => machMaintLog.length);
  await window.click(`[data-act="mt-defer"][data-id="${filterId}"]`);
  const st = await window.evaluate((id) => {
    const tk = machMaintTasks.find((x) => x.id === id);
    return { ...KhaytMaintenance.taskStatus(tk, machineHoursMeter(tk.machineId), Date.now()), lastDoneAt: tk.lastDoneAt, deferUntilAt: tk.deferUntilAt, log: machMaintLog.length };
  }, filterId);
  if (!st.deferred || !st.deferUntilAt) fail(`"Not needed" did not defer the task: ${JSON.stringify(st)}`);
  if (st.log !== logBefore) fail('"Not needed" wrote a maintenance-log row');
  if (Date.now() - Date.parse(st.lastDoneAt) < 99 * 86400000) fail('"Not needed" moved lastDoneAt — it is not a "done"');
  if (await window.$(`[data-act="mt-defer"][data-id="${filterId}"]`)) fail('"Not needed" is still offered on a task that was just deferred');
  console.log('✔ plan matched from the record; 8 tasks added; own interval taken only when ticked; overdue part listed as "order now"; Not needed deferred without a log row');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

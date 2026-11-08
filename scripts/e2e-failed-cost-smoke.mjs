#!/usr/bin/env node
/**
 * E2E: what a failed print really cost — filament, machine time, electricity.
 *
 * A machine with a plug runs a print for nine minutes at 200 W and the printer
 * cancels it at 40%. The meter keeps that reading (it is not the job's: the job
 * goes back to be printed again). Logging waste against the job from its card
 * writes the breakdown beside the filament: 30 Wh metered by the plug, the
 * machine's time at 40% of the estimate, and `cost` left as the filament. The
 * reading is spent on that row, so a second failure logged against the same
 * job is costed at the machine's wattage instead. A QC failure is costed as a
 * print that ran to the end, from the job's own actual time and energy. The
 * Waste screen shows the columns, the true cost and where it went.
 *
 *   node scripts/e2e-failed-cost-smoke.mjs
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

  // The plug: on, drawing 200 W. hubAPI is frozen, so the stub is the handler.
  await electronApp.evaluate(({ ipcMain }) => {
    ipcMain.removeHandler('hub:smart-plug');
    ipcMain.handle('hub:smart-plug', () => ({ ok: true, on: true, watts: 200 }));
  });

  await window.evaluate(() => {
    settings.elecRate = 0.5;
    machines.push({ id: 'M-fc', name: 'Failing Fiona', color: '#a37', powerDraw: 100, wearRate: 2,
      smartPlug: { type: 'shelly', host: '192.168.1.51' } });
    inventory.push({ id: 'S-fc', material: 'PLA', colour: '#ffffff', weight: 1000, remaining: 1000, cost: 20 });
    const part = (f) => ({ fileRef: f, grams: 50, printTime: 1, qty: 1, material: 'PLA' });
    printLog.push({ id: 'ORD-fc', project: 'Cancelled', date: localDateStr(), status: 'printing',
      machineId: 'M-fc', material: 'PLA', printTime: 1, parts: [part('fc.gcode')] });
    printLog.push({ id: 'ORD-qc', project: 'Inspected', date: localDateStr(), status: 'qc',
      machineId: 'M-fc', material: 'PLA', printTime: 2, actualPrintTime: 2, parts: [part('qc.gcode')],
      actualEnergyWh: 50, actualEnergy: { source: 'plug', coverage: 1 } });
    saveAll();
  });

  // Ten readings a minute apart while printing, then the printer cancels at 40%.
  await window.evaluate(async () => {
    const realNow = Date.now;
    let T = realNow.call(Date) + 3600 * 1000;
    Date.now = () => T;
    try {
      const st = (state, p) => ({ 'M-fc': { state, filename: 'fc.gcode', progress: p } });
      for (let i = 0; i < 10; i++) {
        await meterPrintEnergy(st('printing', 4 * (i + 1)));
        T += 60 * 1000;
      }
      await meterPrintEnergy(st('cancelled', 0));   // firmware zeroes progress on a cancel
    } finally { Date.now = realNow; }
  });
  const job = await window.evaluate(() => printLog.find((o) => o.id === 'ORD-fc'));
  if (job.actualEnergyWh !== undefined) fail(`a cancelled print wrote energy on its job: ${job.actualEnergyWh}`);

  // ---- waste logged from the job's card carries the breakdown ----
  const logFromCard = async () => {
    await window.evaluate(() => openLogWasteFromCard('ORD-fc'));
    await window.waitForSelector('#wfc_weight', { timeout: 10_000 });
    await window.fill('#wfc_weight', '20');
    await window.click('.modal-footer [data-act="save"]');
    await window.waitForSelector('#wfc_weight', { state: 'detached', timeout: 5_000 });
    return window.evaluate(() => wasteLog[0]);
  };
  const first = await logFromCard();
  if (first.orderId !== 'ORD-fc') fail(`waste row is not the job's: ${JSON.stringify(first)}`);
  if (first.energyWh !== 30 || first.powerSource !== 'plug') fail(`metered energy not on the row: ${JSON.stringify(first)}`);
  if (first.failedHours !== 0.4 || first.hoursSource !== 'progress') fail(`hours not 40% of the estimate: ${JSON.stringify(first)}`);
  if (first.costMachine !== 0.8) fail(`machine time ${first.costMachine}, wanted 0.4 h × 2 = 0.8`);
  if (first.costPower !== 0.02) fail(`electricity ${first.costPower}, wanted 0.03 kWh × 0.5 ≈ 0.02`);
  if (first.costMaterial !== first.cost) fail(`costMaterial ${first.costMaterial} is not the row's cost ${first.cost}`);
  const sum = Math.round((first.cost + first.costMachine + first.costPower) * 100) / 100;
  if (first.costFull !== sum) fail(`costFull ${first.costFull}, wanted ${sum}`);

  // ---- the reading is spent: a second failure is costed at the wattage ----
  const second = await logFromCard();
  if (second.id === first.id) fail('second waste row was not written');
  if (second.energyWh !== undefined || second.powerSource !== 'rate') fail(`the kept reading was used twice: ${JSON.stringify(second)}`);
  if (second.costPower !== 0.02) fail(`wattage electricity ${second.costPower}, wanted 0.4 h × 0.1 kW × 0.5 = 0.02`);

  // ---- a QC failure ran to the end: the job's own time and energy ----
  const qc = await window.evaluate(() => {
    const order = printLog.find((o) => o.id === 'ORD-qc');
    recordQcFailure(order, { failureType: 'warping', severity: 'major', reason: 'shifted', weight: 30 });
    saveAll();
    return wasteLog.find((w) => w.orderId === 'ORD-qc');
  });
  if (!qc) fail('QC failure wrote no waste row');
  if (qc.failedHours !== 2 || qc.hoursSource !== 'printer') fail(`QC hours not the job's actual: ${JSON.stringify(qc)}`);
  if (qc.energyWh !== 50 || qc.costPower !== 0.03 || qc.costMachine !== 4) fail(`QC breakdown wrong: ${JSON.stringify(qc)}`);

  // ---- the Waste screen ----
  const screen = await window.evaluate(() => {
    renderWasteLog();
    const row = [...document.querySelectorAll('#wasteTable tbody tr')][0];
    const where = document.querySelector('#wasteWhere');
    return {
      cells: row ? row.querySelectorAll('td').length : 0,
      full: row ? row.querySelector('.waste-full')?.textContent.trim() : null,
      trueCost: document.querySelector('#wasteTrueCost')?.textContent.replace(/\s+/g, ' ') || null,
      where: where ? where.textContent.replace(/\s+/g, ' ') : null,
    };
  });
  if (screen.cells !== 10) fail(`waste row has ${screen.cells} cells, wanted 10`);
  if (!screen.trueCost) fail('no true-cost section on the Waste screen');
  if (!/kWh/.test(screen.trueCost)) fail(`true cost has no metered energy: "${screen.trueCost}"`);
  if (!screen.where || !/Failing Fiona/.test(screen.where) || !/3 failures/.test(screen.where)) {
    fail(`where-failures-cost does not group by the printer: "${screen.where}"`);
  }
  // The Waste tab is not the one showing, so the picker is changed as the page would.
  const byMat = await window.evaluate(() => {
    const sel = document.querySelector('#wasteWhereBy');
    sel.value = 'material';
    sel.dispatchEvent(new Event('change'));
    return document.querySelector('#wasteWhere').textContent.replace(/\s+/g, ' ');
  });
  if (!/PLA/.test(byMat)) fail(`by material shows "${byMat}"`);

  console.log('failed-cost smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}

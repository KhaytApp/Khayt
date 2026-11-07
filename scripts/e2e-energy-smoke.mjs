#!/usr/bin/env node
/**
 * E2E: what a print drew from the wall, metered by its smart plug.
 *
 * A machine with a plug runs a print for nine minutes at 200 W, read once a
 * minute (the plug answer is stubbed in the main process; the clock in the
 * window). When the printer leaves the job FINISHED, the job gets
 * `actualEnergyWh` = 30 Wh with full coverage, and the meter memory is empty
 * again. A CANCELLED print writes nothing. With three metered prints the
 * machine editor offers the measured wattage, and "Use this" sets it on the
 * draft. Analytics shows electricity quoted against metered for the machine.
 *
 *   node scripts/e2e-energy-smoke.mjs
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
    machines.push({ id: 'M-e2e', name: 'Plugged', color: '#3a7', powerDraw: 150,
      smartPlug: { type: 'shelly', host: '192.168.1.50' } });
    const part = (f) => ({ fileRef: f, grams: 10, printTime: 0.15, qty: 1 });
    // Two earlier metered prints, so this one makes three for the suggestion.
    for (const n of [1, 2]) {
      printLog.push({ id: 'ORD-old' + n, project: 'Old ' + n, date: localDateStr(), status: 'completed',
        machineId: 'M-e2e', parts: [part('old' + n + '.gcode')], actualPrintTime: 0.15,
        actualEnergyWh: 30, actualEnergy: { source: 'plug', coverage: 1, at: '2026-11-0' + n + 'T10:00:00Z' } });
    }
    printLog.push({ id: 'ORD-e2e', project: 'Metered', date: localDateStr(), status: 'printing',
      machineId: 'M-e2e', parts: [part('part.gcode')], actualPrintTime: 0.15 });
    saveAll();
  });

  // Ten readings a minute apart while printing, then the finish edge.
  const run = (endState, progress, hoursAhead) => window.evaluate(async ({ endState, progress, hoursAhead }) => {
    const realNow = Date.now;
    let T = realNow.call(Date) + hoursAhead * 3600 * 1000;
    Date.now = () => T;
    try {
      const st = (state, p) => ({ 'M-e2e': { state, filename: 'part.gcode', progress: p } });
      for (let i = 0; i < 10; i++) {
        await meterPrintEnergy(st('printing', i * 10));
        T += 60 * 1000;
      }
      await meterPrintEnergy(st(endState, progress));
      await meterPrintEnergy(st('standby', 0));   // a second idle poll is no new edge
    } finally { Date.now = realNow; }
    return JSON.parse(localStorage.getItem('khayt.energyMeters') || '{}');
  }, { endState, progress, hoursAhead });

  // ---- a cancelled print writes nothing ----
  let memo = await run('cancelled', 40, 1);
  if (Object.keys(memo).length) fail(`meter memory not emptied after a cancel: ${JSON.stringify(memo)}`);
  let job = await window.evaluate(() => printLog.find((o) => o.id === 'ORD-e2e'));
  if (job.actualEnergyWh !== undefined) fail(`a cancelled print wrote energy: ${job.actualEnergyWh}`);

  // ---- a finished print writes its energy ----
  memo = await run('complete', 100, 2);
  if (Object.keys(memo).length) fail(`meter memory not emptied after a finish: ${JSON.stringify(memo)}`);
  job = await window.evaluate(() => printLog.find((o) => o.id === 'ORD-e2e'));
  if (job.actualEnergyWh !== 30) fail(`actualEnergyWh = ${job.actualEnergyWh}, wanted 30 (200 W × 9 min)`);
  const e = job.actualEnergy || {};
  if (e.source !== 'plug' || e.coverage !== 1 || e.samples !== 10 || e.gaps !== 0) {
    fail(`actualEnergy not as metered: ${JSON.stringify(e)}`);
  }

  // ---- the machine editor offers the measured wattage ----
  await window.evaluate(() => { printLog.find((o) => o.id === 'ORD-e2e').status = 'completed'; saveAll(); openMachineEditor('M-e2e'); });
  await window.waitForSelector('#machPowerUse', { timeout: 10_000 });
  const line = await window.$eval('#machPowerMeasured', (el) => el.textContent);
  if (!/200/.test(line) || !/3/.test(line)) fail(`measured line says "${line.trim()}", wanted 200 W over 3 prints`);
  await window.click('#machPowerUse');
  const after = await window.$eval('#machPowerMeasured', (el) => el.textContent);
  if (!/200/.test(after) || (await window.$('#machPowerUse'))) fail(`"Use this" did not take: "${after.trim()}"`);
  await window.keyboard.press('Escape');

  // ---- analytics: quoted against metered ----
  const power = await window.evaluate(() => {
    KhaytAnalytics.renderMachineAccuracy();
    const row = document.querySelector('#machinePowerSection .power-row[data-machine="M-e2e"]');
    return row ? row.textContent.replace(/\s+/g, ' ') : null;
  });
  if (!power) fail('no electricity row for the metered machine');
  if (!/0\.09 kWh/.test(power)) fail(`electricity row is "${power}", wanted 0.09 kWh over three prints`);

  console.log('energy smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}

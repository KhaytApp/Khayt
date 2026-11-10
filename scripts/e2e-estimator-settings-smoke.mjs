#!/usr/bin/env node
/**
 * E2E: the estimator uses the shop's numbers, and its own history.
 *
 * The constants used to be hardcoded — a shop printing PETG at 40% infill had
 * its quotes built on PLA at 20%, and every geometric time estimate assumed
 * about 35 g/h, which no real FDM machine sustains.
 *
 * The arithmetic is unit-tested. What only a running app can show is that the
 * settings panel writes something the estimator actually reads, and that a
 * measured rate takes over from the typed one once the shop has the history.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

const CUBE = { volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } };

async function openPanel(window) {
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="printers"]');
  await window.waitForSelector('#est_density');
}

const estimateNow = (window, cube) => window.evaluate((c) => {
  const opts = KhaytStl.fromSettings(settings);
  return KhaytStl.estimateFromStl(c, opts);
}, cube);

async function testPanelWritesWhatTheEstimatorReads(window) {
  const before = await estimateNow(window, CUBE);

  await window.evaluate(() => {
    const el = document.querySelector('#estimatorSettings');
    const set = (sel, v) => {
      const f = el.querySelector(sel);
      f.value = String(v);
      f.dispatchEvent(new Event('change', { bubbles: true }));
    };
    set('#est_density', 1.27);   // PETG
    set('#est_infill', 60);      // a shop that prints strong parts
    set('#est_wall', 2.4);       // 6 perimeters — a shop printing functional parts
  });

  const stored = await window.evaluate(() => JSON.parse(JSON.stringify(settings.estimator || {})));
  if (Math.abs(stored.densityGPerCm3 - 1.27) > 1e-9) throw new Error(`density stored as ${stored.densityGPerCm3}`);
  if (Math.abs(stored.infillPct - 0.6) > 1e-9) {
    throw new Error(`infill stored as ${stored.infillPct} — should be a fraction, not 60`);
  }
  // Wall thickness is what the shell is derived from now, so a shop that cannot
  // set it cannot correct its own estimates. It is stored in mm, not as a
  // percent, which is the mistake the infill check above exists to catch.
  if (Math.abs(stored.wallThicknessMm - 2.4) > 1e-9) {
    throw new Error(`wall thickness stored as ${stored.wallThicknessMm}, expected 2.4 mm`);
  }

  const after = await estimateNow(window, CUBE);
  if (!(after.estWeightG > before.estWeightG)) {
    throw new Error(`60% infill in PETG should weigh more: ${after.estWeightG} vs ${before.estWeightG}`);
  }
  if (after.assumptions.densityGPerCm3 !== 1.27) {
    throw new Error('the estimator did not pick up the shop density');
  }
}

/** Percent fields must survive a round trip through the panel. */
async function testPercentsRoundTrip(window) {
  await window.evaluate(() => renderEstimatorSettings());
  const shown = await window.evaluate(() => ({
    infill: document.querySelector('#est_infill').value,
    density: document.querySelector('#est_density').value,
    wall: document.querySelector('#est_wall').value,
  }));
  if (Number(shown.infill) !== 60) throw new Error(`the panel redisplays infill as ${shown.infill}`);
  if (Number(shown.density) !== 1.27) throw new Error(`density redisplayed as ${shown.density}`);
  if (Number(shown.wall) !== 2.4) throw new Error(`wall thickness redisplayed as ${shown.wall}`);
}

/** With no history the rate is admitted to be an assumption. */
async function testUncalibratedSaysSo(window) {
  const txt = await window.evaluate(() => document.querySelector('#estimatorSettings').textContent);
  if (!/assumption/i.test(txt)) {
    throw new Error(`with no measured jobs the panel should admit it is guessing: ${txt.slice(-300)}`);
  }
  const disabled = await window.evaluate(() => document.querySelector('#est_rate').disabled);
  if (disabled) throw new Error('with nothing measured the shop must still be able to type a rate');
}

/** Once the shop has measured jobs, its own rate takes over and is named. */
async function testMeasuredRateTakesOver(window) {
  const before = await estimateNow(window, CUBE);

  await window.evaluate(() => {
    const measured = { time: 'moonraker', weight: 'moonraker' };
    const job = (h, g) => ({
      id: 'CAL-' + h, machineId: 'M1',
      actualPrintTime: h, actualWeight: g, actualsSource: measured,
      parts: [{ id: 'p', printFileId: 'F1', setupId: 'S1', printTime: h, printWeight: g, qty: 1 }],
    });
    // A shop that really prints about 12 g/h, not the 35 the default implies.
    printLog.unshift(job(3, 36), job(4, 49), job(2, 23), job(5, 62));
    saveAll();
    renderEstimatorSettings();
  });

  const txt = await window.evaluate(() => document.querySelector('#estimatorSettings').textContent);
  if (!/Measured/i.test(txt)) throw new Error(`the panel should now say it measured the rate: ${txt.slice(-300)}`);
  if (!/12/.test(txt)) throw new Error(`the measured rate is not shown: ${txt.slice(-300)}`);

  // And it must reach a real estimate, not just the panel's own label.
  const calibrated = await window.evaluate((c) => {
    const opts = KhaytEstimateCalibration.applyCalibration(
      KhaytStl.fromSettings(settings),
      KhaytEstimateCalibration.calibrate(printLog, { allocate: KhaytOrderFileLink.allocateActuals }, {}));
    return { est: KhaytStl.estimateFromStl(c, opts), from: opts.calibratedFrom };
  }, CUBE);

  if (!calibrated.from) throw new Error('the estimate does not record that it was calibrated');
  if (!(calibrated.est.estPrintTimeH > before.estPrintTimeH)) {
    throw new Error(`a slower measured rate should mean a longer job: ${calibrated.est.estPrintTimeH} vs ${before.estPrintTimeH}`);
  }
  if (Math.abs(calibrated.est.estWeightG - before.estWeightG) > 0.01) {
    throw new Error('the WEIGHT changed — only the time was ever guessed');
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await openPanel(window);

  await testPanelWritesWhatTheEstimatorReads(window);
  await testPercentsRoundTrip(window);
  await testUncalibratedSaysSo(window);
  await testMeasuredRateTakesOver(window);

  console.log('e2e-estimator-settings: ok (panel read back, percents, admits guessing, measured rate takes over)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

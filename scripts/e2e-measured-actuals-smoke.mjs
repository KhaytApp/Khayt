#!/usr/bin/env node
/**
 * E2E: the completion dialog offers what the PRINTER measured.
 *
 * The unit tests prove lib/printer-actuals.js picks the right numbers. What only
 * a running app can show is that they reach the two inputs a shop actually types
 * into — and that when there is no measurement, the dialog quietly goes back to
 * the estimate instead of claiming one.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

/** Put a machine, an order and a frozen completion in front of the dialog. */
async function seed(window, { completion }) {
  await window.evaluate(({ completion }) => {
    if (!machines.some((m) => m.id === 'E2E-M1')) {
      machines.push({ id: 'E2E-M1', name: 'E2E Printer', printerApi: { type: 'moonraker' } });
    }
    // The order the shop is about to mark complete: a 3 hour, 40 g estimate.
    window.__e2eOrder = {
      id: 'E2E-ORDER-1',
      machineId: 'E2E-M1',
      printTime: 3,
      parts: [{ printWeight: 40, qty: 1 }],
      actualPrintTime: null,
      actualWeight: null,
    };
    machineStatusCache = { 'E2E-M1': completion ? { state: 'complete', lastCompleted: completion } : {} };
  }, { completion });
}

async function openDialog(window) {
  await window.evaluate(() => {
    window.__e2eConfirmed = false;
    promptActuals(window.__e2eOrder, () => { window.__e2eConfirmed = true; });
  });
  await window.waitForSelector('#actTime');
}

const readDialog = (window) => window.evaluate(() => {
  const modal = document.querySelector('#actTime')?.closest('.modal, [class*="modal"]') || document;
  return {
    time: document.querySelector('#actTime')?.value,
    weight: document.querySelector('#actWeight')?.value,
    text: modal.textContent || '',
  };
});

async function closeDialog(window) {
  await window.evaluate(() => {
    const cancel = document.querySelector('[data-act="cancel"]');
    if (cancel) cancel.click();
  });
  await window.waitForSelector('#actTime', { state: 'detached' }).catch(() => {});
}

/** A real measurement must reach the fields, and be labelled as measured. */
async function testMeasuredIsOffered(window) {
  await seed(window, {
    completion: {
      at: Date.now() - 60_000,
      filename: 'bracket.gcode',
      // 11560 s = 3.21 h, against a 3 h estimate. 41.83 g against 40 g.
      actuals: { filamentGrams: 41.83, durationS: 11560, source: 'moonraker' },
    },
  });
  await openDialog(window);
  const d = await readDialog(window);

  if (Number(d.time) !== 3.21) throw new Error(`time field was ${d.time}, expected the measured 3.21`);
  if (Math.abs(Number(d.weight) - 41.8) > 0.05) throw new Error(`weight field was ${d.weight}, expected ~41.8`);
  if (Number(d.time) === 3) throw new Error('the dialog re-offered the estimate');
  if (!/Measured/i.test(d.text)) throw new Error(`the dialog does not say the figures are measured: ${d.text.slice(0, 300)}`);
  if (!/moonraker/i.test(d.text)) throw new Error('the dialog does not name where they came from');
  // Naming the adapter is not naming the JOB. A completion stays offerable for
  // 24 hours, and a shop running five-hour prints back to back starts the next
  // one long before that — so the figures on screen can belong to the previous
  // print while wearing a green "Measured" label. The only thing that lets the
  // shop notice is seeing which file they were measured on.
  if (!/bracket\.gcode/i.test(d.text)) {
    throw new Error(`the dialog does not say WHICH job these figures came from: ${d.text.slice(0, 300)}`);
  }
  await closeDialog(window);
}

/** With no measurement it falls back to the estimate — and claims nothing. */
async function testNoMeasurementFallsBack(window) {
  await seed(window, { completion: null });
  await openDialog(window);
  const d = await readDialog(window);

  if (Number(d.time) !== 3) throw new Error(`time field was ${d.time}, expected the 3 h estimate`);
  if (Number(d.weight) !== 40) throw new Error(`weight field was ${d.weight}, expected the 40 g estimate`);
  if (/Measured/i.test(d.text)) {
    throw new Error('an estimate was labelled as measured — the exact failure this work exists to prevent');
  }
  await closeDialog(window);
}

/** A stale completion belongs to some other job. */
async function testStaleIsNotOffered(window) {
  await seed(window, {
    completion: {
      at: Date.now() - 48 * 60 * 60 * 1000,
      filename: 'last-week.gcode',
      actuals: { filamentGrams: 999, durationS: 99999, source: 'moonraker' },
    },
  });
  await openDialog(window);
  const d = await readDialog(window);
  if (Number(d.weight) === 999) throw new Error('a two-day-old completion was attached to today\'s order');
  if (Number(d.time) !== 3) throw new Error(`expected the estimate, got ${d.time}`);
  await closeDialog(window);
}

/** Confirming records where each figure came from. */
async function testProvenanceIsRecorded(window) {
  await seed(window, {
    completion: {
      at: Date.now() - 60_000,
      filename: 'bracket.gcode',
      actuals: { filamentGrams: 41.83, durationS: 11560, source: 'moonraker' },
    },
  });
  await openDialog(window);
  await window.evaluate(() => {
    const save = document.querySelector('[data-act="save"]');
    if (!save) throw new Error('no confirm button in the modal');
    save.click();
  });
  await window.waitForFunction(() => window.__e2eConfirmed === true, null, { timeout: 15_000 });
  const order = await window.evaluate(() => JSON.parse(JSON.stringify(window.__e2eOrder)));

  if (order.actualPrintTime !== 3.21) throw new Error(`actualPrintTime was ${order.actualPrintTime}`);
  if (Math.abs(order.actualWeight - 41.8) > 0.05) throw new Error(`actualWeight was ${order.actualWeight}`);
  if (!order.actualsSource) throw new Error('nothing recorded where the figures came from');
  if (order.actualsSource.time !== 'moonraker') {
    throw new Error(`time provenance was ${order.actualsSource.time}, expected moonraker`);
  }
  if (order.actualsSource.weight !== 'moonraker') {
    throw new Error(`weight provenance was ${order.actualsSource.weight}`);
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'queue-tab');

  await testMeasuredIsOffered(window);
  await testNoMeasurementFallsBack(window);
  await testStaleIsNotOffered(window);
  await testProvenanceIsRecorded(window);

  console.log('e2e-measured-actuals: ok (measured offered, estimate fallback, stale refused, provenance kept)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

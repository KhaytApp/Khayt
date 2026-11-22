#!/usr/bin/env node
/**
 * E2E: a finished job teaches the file it printed.
 *
 * This is the loop the previous five features could not close. The arithmetic is
 * unit-tested; what only a running app can show is that a part picked from the
 * library carries its link through the calculator into the order, and that
 * completing that order feeds the setup's record without anyone logging it by
 * hand.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

const FILE_ID = 'E2E-LINK-FILE';
const SETUP_ID = 'E2E-LINK-SETUP';

async function seed(window) {
  await window.evaluate(([fileId, setupId]) => {
    if (!Array.isArray(window.printFiles)) printFiles = [];
    printFiles.length = 0;
    printFiles.push({
      id: fileId, name: 'Linked Bracket', originalName: 'bracket.3mf',
      createdAt: Date.now(), parsed: {}, tags: [], folder: '',
      setups: [{
        id: setupId, name: 'Draft PLA', material: 'PLA',
        layerHeightMm: 0.28, nozzleMm: 0.4,
        ok: 0, failed: 0, createdAt: new Date().toISOString(),
      }],
    });
    renderPrintFiles();
    document.dispatchEvent(new CustomEvent('khayt:printfiles-changed'));
  }, [FILE_ID, SETUP_ID]);
}

/** Pick the file in the calculator and confirm the setup picker follows. */
async function testPickerLinksAPart(window) {
  await switchTab(window, 'calculator-tab');
  await window.waitForSelector('#partPrintFile');

  const options = await window.evaluate(() =>
    [...document.querySelectorAll('#partPrintFile option')].map((o) => o.value));
  if (!options.includes(FILE_ID)) throw new Error(`the library file is not offered: ${options}`);

  await window.selectOption('#partPrintFile', FILE_ID);
  const state = await window.evaluate(() => ({
    setupDisabled: document.querySelector('#partSetup').disabled,
    setupValue: document.querySelector('#partSetup').value,
    fileRef: document.querySelector('#partFileRef').value,
  }));
  if (state.setupDisabled) throw new Error('the setup picker stayed disabled');
  if (state.setupValue !== SETUP_ID) {
    throw new Error(`the known setup was not pre-selected: ${state.setupValue}`);
  }
  if (!/bracket/i.test(state.fileRef)) {
    throw new Error(`the file reference was not filled in: "${state.fileRef}"`);
  }
}

/** The link has to survive the trip into the part object. */
async function testTheLinkReachesThePart(window) {
  const part = await window.evaluate(() => {
    document.querySelector('#printWeight').value = '40';
    document.querySelector('#printTime').value = '3';
    const p = snapshotPartFromForm();
    return { printFileId: p.printFileId, setupId: p.setupId };
  });
  if (part.printFileId !== FILE_ID) throw new Error(`part.printFileId was ${part.printFileId}`);
  if (part.setupId !== SETUP_ID) throw new Error(`part.setupId was ${part.setupId}`);
}

/** A second part must not silently inherit the first one's model. */
async function testTheLinkIsClearedBetweenParts(window) {
  await window.evaluate(() => {
    document.querySelector('#partName').value = 'First';
    addPart();
  });
  const after = await window.evaluate(() => document.querySelector('#partPrintFile').value);
  if (after !== '') {
    throw new Error(`the model carried over to the next part: ${after}`);
  }
}

/** Completing an order records against the setup, without anyone logging it. */
async function testCompletionTeachesTheSetup(window) {
  const before = await window.evaluate((f) =>
    printFiles.find((x) => x.id === f).setups[0].ok, FILE_ID);
  if (before !== 0) throw new Error(`expected a fresh setup, ok was ${before}`);

  const touched = await window.evaluate(([fileId, setupId]) => {
    const order = {
      id: 'E2E-LINK-ORDER', printTime: 3,
      parts: [
        { id: 'a', printFileId: fileId, setupId, printTime: 1.5, printWeight: 20, qty: 1 },
        { id: 'b', printFileId: fileId, setupId, printTime: 1.5, printWeight: 20, qty: 1 },
      ],
    };
    return recordSetupOutcomes(order, true);
  }, [FILE_ID, SETUP_ID]);

  const su = await window.evaluate((f) =>
    JSON.parse(JSON.stringify(printFiles.find((x) => x.id === f).setups[0])), FILE_ID);
  if (touched !== 1) throw new Error(`two parts sharing one setup should be ONE outcome, got ${touched}`);
  if (su.ok !== 1) throw new Error(`expected 1 success, got ${su.ok}`);
  if (!su.lastOkAt) throw new Error('no timestamp recorded');

  // …and that is enough for the setup to read as known-good.
  const status = await window.evaluate((f) =>
    KhaytPrintSetups.statusOf(printFiles.find((x) => x.id === f).setups[0]), FILE_ID);
  if (status !== 'known-good') throw new Error(`status was ${status}`);
}

/** A failed job teaches the same setup the other way. */
async function testAFailureIsRecordedToo(window) {
  await window.evaluate(([fileId, setupId]) => {
    recordSetupOutcomes({
      id: 'E2E-LINK-ORDER-2',
      parts: [{ id: 'a', printFileId: fileId, setupId, printTime: 3, printWeight: 40 }],
    }, false);
  }, [FILE_ID, SETUP_ID]);
  const su = await window.evaluate((f) =>
    JSON.parse(JSON.stringify(printFiles.find((x) => x.id === f).setups[0])), FILE_ID);
  if (su.failed !== 1) throw new Error(`expected 1 failure, got ${su.failed}`);
  if (su.ok !== 1) throw new Error('the earlier success was lost');
}

/** The margin question, answered — and only from the jobs that can answer it. */
async function testVarianceUsesOnlyCleanJobs(window) {
  const r = await window.evaluate(([fileId, setupId]) => {
    const orders = [
      // One part, measured: an exact comparison.
      { id: 'clean', actualPrintTime: 3.5, actualWeight: 44,
        actualsSource: { time: 'moonraker', weight: 'moonraker' },
        parts: [{ id: 'a', printFileId: fileId, setupId, printTime: 3, printWeight: 40, qty: 1 }] },
      // Two parts: the actual had to be divided by the estimate to attribute it.
      { id: 'mixed', actualPrintTime: 20, actualWeight: 200,
        actualsSource: { time: 'moonraker', weight: 'moonraker' },
        parts: [
          { id: 'a', printFileId: fileId, setupId, printTime: 3, printWeight: 40, qty: 1 },
          { id: 'b', printFileId: 'OTHER', setupId: 'OTHER', printTime: 7, printWeight: 60, qty: 1 }] },
    ];
    const all = KhaytOrderFileLink.setupPerformance(orders, { printFileId: fileId, setupId });
    const exact = KhaytOrderFileLink.setupPerformance(orders, { printFileId: fileId, setupId, exactOnly: true });
    return { all, exact };
  }, [FILE_ID, SETUP_ID]);

  if (r.all.jobs !== 2) throw new Error(`expected 2 jobs total, got ${r.all.jobs}`);
  if (r.all.exactJobs !== 1 || r.all.apportionedJobs !== 1) {
    throw new Error(`the two kinds were not counted apart: ${JSON.stringify(r.all)}`);
  }
  if (r.exact.jobs !== 1) throw new Error(`exactOnly should see 1 job, saw ${r.exact.jobs}`);
  if (r.exact.hoursDeltaPct !== 16.7) {
    throw new Error(`the clean job says +16.7%, got ${r.exact.hoursDeltaPct}`);
  }
  if (r.all.hoursDeltaPct === r.exact.hoursDeltaPct) {
    throw new Error('the apportioned job made no difference — the split is not doing anything');
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'printfiles-tab');
  await seed(window);

  await testPickerLinksAPart(window);
  await testTheLinkReachesThePart(window);
  await testTheLinkIsClearedBetweenParts(window);
  await testCompletionTeachesTheSetup(window);
  await testAFailureIsRecordedToo(window);
  await testVarianceUsesOnlyCleanJobs(window);

  console.log('e2e-order-file-link: ok (picker, part, cleared, taught, failed, variance)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

#!/usr/bin/env node
/**
 * E2E: one print, several files.
 *
 * lib/print-file-parts.js was correct, tested and reachable from nothing for a
 * whole release — `partsOf` was read for the size chip and the other six verbs
 * had no caller. Unit tests cannot see that, and neither can a source-text
 * guard on its own: both pass while the shop stares at a card that offers none
 * of it. So this drives the real screen.
 *
 * What it proves:
 *   the parts are listed, and the main one is marked;
 *   the row's buttons exist and are reachable (they live in a closed <details>);
 *   making another part the main one REORDERS the record and moves the mark;
 *   removing a part takes it off the record and leaves the rest alone;
 *   a single-file print grows no parts list and is untouched by any of it.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

const KIT = 'E2E-PF-KIT';
const SOLO = 'E2E-PF-SOLO';

const part = (name, size) => ({ filename: name, originalName: name, size, ext: 'stl', kind: 'model' });

async function seed(window) {
  await window.evaluate(([kit, solo]) => {
    const f = (name, size) => ({ filename: name, originalName: name, size, ext: 'stl', kind: 'model' });
    if (!Array.isArray(window.printFiles)) printFiles = [];
    printFiles.length = 0;
    const base = { createdAt: Date.now(), updatedAt: Date.now(), parsed: {}, colors: [], tags: [], folder: '', material: '', favorite: false };
    printFiles.push({
      ...base, id: kit, name: 'E2E Spiderman', originalName: 'torso.stl',
      files: [f('torso.stl', 4000), f('head.stl', 1000), f('arm-left.stl', 500)],
      sourceFile: f('torso.stl', 4000),
    });
    printFiles.push({
      ...base, id: solo, name: 'E2E Bracket', originalName: 'bracket.stl',
      sourceFile: f('bracket.stl', 900),
    });
    renderPrintFiles();
  }, [KIT, SOLO]);
  await window.waitForSelector(`.pf-card[data-id="${KIT}"]`);
}

/** The parts list is a closed <details>; a shop opens it, so open it. */
async function openParts(window, id) {
  const ok = await window.evaluate((fileId) => {
    const d = document.querySelector(`.pf-card[data-id="${fileId}"] details.pf-parts`);
    if (!d) return false;
    d.setAttribute('open', '');
    return true;
  }, id);
  if (!ok) throw new Error(`${id} has no parts list on its card`);
  await window.waitForSelector(`.pf-card[data-id="${id}"] .pf-part`, { state: 'visible' });
}

const rows = (window, id) => window.evaluate((fileId) => {
  const card = document.querySelector(`.pf-card[data-id="${fileId}"]`);
  return [...card.querySelectorAll('.pf-part')].map((el) => ({
    name: el.querySelector('.pf-part-name')?.textContent.trim(),
    primary: el.classList.contains('is-primary'),
    tagged: !!el.querySelector('.pf-part-tag'),
    acts: [...el.querySelectorAll('[data-act]')].map((b) => b.dataset.act),
    fn: el.querySelector('[data-act="pf-part-open"]')?.dataset.fn,
  }));
}, id);

const record = (window, id) => window.evaluate((fileId) =>
  JSON.parse(JSON.stringify(printFiles.find((r) => r.id === fileId))), id);

async function testTheCardListsTheParts(window) {
  await openParts(window, KIT);
  const r = await rows(window, KIT);
  if (r.length !== 3) throw new Error(`expected 3 parts on the card, got ${r.length}`);
  if (r.map((x) => x.name).join() !== 'torso.stl,head.stl,arm-left.stl') {
    throw new Error(`the parts are not listed in the record's order: ${r.map((x) => x.name).join()}`);
  }
  // Marked, not merely first: which file the card SPEAKS FOR has to be visible.
  if (!r[0].primary || !r[0].tagged) throw new Error('the main file is not marked as such');
  if (r[1].primary || r[2].primary) throw new Error('more than one part is marked as the main file');
  // The verbs the module exports, as controls a shop can reach.
  if (!r[1].acts.includes('pf-part-primary')) throw new Error('a part cannot be made the main file');
  if (!r[1].acts.includes('pf-part-del')) throw new Error('a part cannot be removed');
  if (!r[1].acts.includes('pf-part-open')) throw new Error('a part cannot be opened');
  // Not offered on the one that already is it.
  if (r[0].acts.includes('pf-part-primary')) throw new Error('the main file is offered as a choice for main file');
}

async function testMakingAPartTheMainOneReordersTheRecord(window) {
  await window.click(`.pf-card[data-id="${KIT}"] [data-act="pf-part-primary"][data-fn="head.stl"]`);
  await window.waitForSelector(`.pf-card[data-id="${KIT}"] .pf-part`, { state: 'attached' });
  const rec = await record(window, KIT);
  if (rec.files.map((f) => f.filename).join() !== 'head.stl,torso.stl,arm-left.stl') {
    throw new Error(`the parts did not reorder: ${rec.files.map((f) => f.filename).join()}`);
  }
  // The redundancy lib/print-file-parts.js exists to keep: twenty readers still
  // ask sourceFile what this card is about.
  if (rec.sourceFile.filename !== 'head.stl') {
    throw new Error(`sourceFile still points at the old main file: ${rec.sourceFile.filename}`);
  }
  await openParts(window, KIT);
  const r = await rows(window, KIT);
  if (!r[0].primary || r[0].name !== 'head.stl') throw new Error('the mark did not move with the main file');
}

async function testRemovingAPartLeavesTheRestAlone(window) {
  await openParts(window, KIT);
  await window.click(`.pf-card[data-id="${KIT}"] [data-act="pf-part-del"][data-fn="arm-left.stl"]`);
  await window.waitForSelector('.modal [data-act="save"]');
  await window.click('.modal [data-act="save"]');
  await window.waitForSelector('.modal', { state: 'detached' });
  const rec = await record(window, KIT);
  if (rec.files.map((f) => f.filename).join() !== 'head.stl,torso.stl') {
    throw new Error(`removing one part changed the others: ${rec.files.map((f) => f.filename).join()}`);
  }
  if (rec.sourceFile.filename !== 'head.stl') throw new Error('removing a part moved the main file');
}

async function testASingleFilePrintIsUntouched(window) {
  const has = await window.evaluate((id) =>
    !!document.querySelector(`.pf-card[data-id="${id}"] details.pf-parts`), SOLO);
  if (has) throw new Error('a print of one file grew a parts list');
  const rec = await record(window, SOLO);
  if (rec.files) throw new Error('a print of one file gained a files[] it never asked for');
  if (rec.sourceFile.filename !== 'bracket.stl') throw new Error('a single-file record was rewritten');
}

async function testAddingFilesIsOffered(window) {
  // In the overflow, on every card — any print can gain a part, not only one
  // that already has several.
  for (const id of [KIT, SOLO]) {
    const found = await window.evaluate((fileId) =>
      !!document.querySelector(`.pf-card[data-id="${fileId}"] [data-act="pf-add-parts"]`), id);
    if (!found) throw new Error(`${id} offers no way to add files to the print`);
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'printfiles-tab');
  await seed(window);

  await testTheCardListsTheParts(window);
  await testMakingAPartTheMainOneReordersTheRecord(window);
  await testRemovingAPartLeavesTheRestAlone(window);
  await testASingleFilePrintIsUntouched(window);
  await testAddingFilesIsOffered(window);

  console.log('e2e-multi-part-print: ok (listed, marked, promoted, removed, single-file untouched, add offered)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

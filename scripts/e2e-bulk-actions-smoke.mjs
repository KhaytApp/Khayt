#!/usr/bin/env node
/**
 * E2E: working on many files at once.
 *
 * Groups and categories are worth nothing at scale without this. Filing two
 * hundred kings one dialog at a time is not filing them, so the feature shipped
 * yesterday is only half a feature until a shop can select a set and act on it.
 *
 * What it proves:
 *   selection survives the filter moving — narrow, take, narrow again, take;
 *   bulk filing goes through lib/organise.js, so 200 records end up spelled the
 *     same rather than however each was typed;
 *   an empty box CLEARS rather than doing nothing;
 *   bulk tagging ADDS without discarding what each file already carried, and
 *     removing takes only what was asked for;
 *   bulk delete names the count and takes exactly the held records.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

async function seed(window) {
  await window.evaluate(() => {
    const f = (n) => ({ filename: n, originalName: n, size: 900, ext: 'stl', kind: 'model' });
    if (!Array.isArray(window.printFiles)) printFiles = [];
    printFiles.length = 0;
    const b = { createdAt: Date.now(), updatedAt: Date.now(), parsed: {}, colors: [], material: '', favorite: false };
    // Two categories, no groups. The shop is about to file them.
    ['A', 'B', 'C'].forEach((k) => printFiles.push({ ...b, id: 'BUST-' + k, name: 'Bust ' + k, sourceFile: f(k + '.stl'), category: 'Busts', tags: ['grayscale'] }));
    ['X', 'Y'].forEach((k) => printFiles.push({ ...b, id: 'MINI-' + k, name: 'Mini ' + k, sourceFile: f(k + '.stl'), category: 'Minis', tags: [] }));
    printFiles.push({ ...b, id: 'KEEP-1', name: 'Untouched', sourceFile: f('keep.stl'), category: 'Minis', tags: ['keepme'] });
    // A group already spelled one way, so a bulk edit has something to match.
    printFiles[0].group = 'Saudi Kings'; printFiles[0].folder = 'Saudi Kings';
    renderPrintFiles();
  });
  await window.waitForSelector('.pf-card[data-id="BUST-A"]');
}

const rec = (window, id) => window.evaluate((i) =>
  JSON.parse(JSON.stringify(printFiles.find((r) => r.id === i) || null)), id);
const ids = (window) => window.evaluate(() => printFiles.map((r) => r.id));
const bulkText = (window) => window.evaluate(() => document.getElementById('pfBulk')?.textContent.replace(/\s+/g, ' ').trim() || '');

async function on(window) {
  await window.click('[data-act="pf-select-toggle"]');
  await window.waitForSelector('.pf-bulk');
}

async function testSelectionSurvivesTheFilterMoving(window) {
  await on(window);
  // Narrow to the busts and take all of them…
  await window.click('.pf-folderbar [data-cat="Busts"]');
  await window.click('[data-act="pf-pick-all"]');
  let txt = await bulkText(window);
  if (!/3 selected/.test(txt)) throw new Error(`after taking the busts: ${txt}`);
  // …then to the minis, and take those too. THIS is how a big set is selected,
  // and a count of "selected AND visible" would make it impossible to trust.
  await window.click('.pf-folderbar [data-cat="Minis"]');
  await window.click('[data-act="pf-pick-all"]');
  txt = await bulkText(window);
  if (!/6 selected/.test(txt)) throw new Error(`the earlier selection was lost when the filter moved: ${txt}`);
  // Drop one back off, by its own checkbox.
  await window.click('.pf-card[data-id="KEEP-1"] [data-act="pf-pick"]');
  txt = await bulkText(window);
  if (!/5 selected/.test(txt)) throw new Error(`unticking one card: ${txt}`);
  await window.click('.pf-folderbar [data-cat="Minis"]');   // clear the filter
}

async function testBulkFilingUnifiesTheSpelling(window) {
  await window.click('[data-act="pf-bulk-group"]');
  await window.waitForSelector('#pfBulkName');
  await window.fill('#pfBulkName', 'saudi kings');          // the wrong case, on purpose
  await window.click('.modal [data-act="save"]');
  await window.waitForSelector('.modal', { state: 'detached' });
  for (const id of ['BUST-A', 'BUST-B', 'BUST-C', 'MINI-X', 'MINI-Y']) {
    const r = await rec(window, id);
    if (r.group !== 'Saudi Kings') throw new Error(`${id} was filed as "${r.group}" — the spelling did not unify`);
    if (r.folder !== 'Saudi Kings') throw new Error(`${id} did not get the old field: ${r.folder}`);
  }
  const kept = await rec(window, 'KEEP-1');
  if (kept.group) throw new Error(`a file that was not selected got filed anyway: ${kept.group}`);
}

async function testAnEmptyBoxClears(window) {
  await window.click('[data-act="pf-bulk-group"]');
  await window.waitForSelector('#pfBulkName');
  await window.fill('#pfBulkName', '');
  await window.click('.modal [data-act="save"]');
  await window.waitForSelector('.modal', { state: 'detached' });
  const r = await rec(window, 'BUST-A');
  if (r.group !== '') throw new Error(`an empty box did not take the file out of the group: "${r.group}"`);
  if (r.folder !== '') throw new Error(`the old field kept a group that was cleared: "${r.folder}"`);
  // And nothing else on the record moved.
  if (r.category !== 'Busts') throw new Error(`clearing the group cleared the category too: ${r.category}`);
}

async function testTaggingAddsWithoutDiscarding(window) {
  await window.click('[data-act="pf-bulk-tag"]');
  await window.waitForSelector('#pfBulkTags');
  await window.fill('#pfBulkTags', 'resin');
  await window.click('.modal [data-act="save"]');
  await window.waitForSelector('.modal', { state: 'detached' });
  const a = await rec(window, 'BUST-A');
  if (!a.tags.includes('resin')) throw new Error(`the tag was not added: ${a.tags}`);
  // The whole point: a bulk edit that REPLACED the list would throw this away.
  if (!a.tags.includes('grayscale')) throw new Error(`bulk tagging discarded a file's own tags: ${a.tags}`);
  const x = await rec(window, 'MINI-X');
  if (x.tags.join() !== 'resin') throw new Error(`a file with no tags got the wrong list: ${x.tags}`);
  const kept = await rec(window, 'KEEP-1');
  if (kept.tags.join() !== 'keepme') throw new Error(`an unselected file was tagged: ${kept.tags}`);

  // …and removing takes only what was asked for.
  await window.click('[data-act="pf-bulk-tag"]');
  await window.waitForSelector('#pfBulkTags');
  await window.fill('#pfBulkTags', 'resin');
  await window.click('#pfTagRemove');
  await window.click('.modal [data-act="save"]');
  await window.waitForSelector('.modal', { state: 'detached' });
  const a2 = await rec(window, 'BUST-A');
  if (a2.tags.includes('resin')) throw new Error(`the tag was not removed: ${a2.tags}`);
  if (!a2.tags.includes('grayscale')) throw new Error(`removing one tag took another: ${a2.tags}`);
}

async function testBulkDeleteTakesExactlyTheHeldRecords(window) {
  const before = await ids(window);
  if (before.length !== 6) throw new Error(`expected 6 records before deleting, got ${before.length}`);
  // Narrow the view so part of the held selection is off screen. The Mac lost
  // 34 models to exactly this; the dialog has to say so.
  await window.click('.pf-folderbar [data-cat="Busts"]');
  await window.click('[data-act="pf-bulk-del"]');
  await window.waitForSelector('.modal [data-act="save"]');
  const hiddenNote = await window.evaluate(() => document.querySelector('.modal .pf-del-hidden')?.textContent || '');
  if (!/\d/.test(hiddenNote)) throw new Error(`the dialog did not say part of the selection is off screen: "${hiddenNote}"`);
  // The count is in the sentence AND the button: this is the most expensive
  // mistake this screen can make.
  const label = await window.evaluate(() => document.querySelector('.modal [data-act="save"]').textContent.trim());
  if (!/5/.test(label)) throw new Error(`the delete button does not say how many: "${label}"`);
  await window.click('.modal [data-act="save"]');
  await window.waitForSelector('.modal', { state: 'detached' });
  const after = await ids(window);
  if (after.join() !== 'KEEP-1') throw new Error(`delete took the wrong records, left: ${after}`);
  const txt = await bulkText(window);
  if (!/0 selected/.test(txt)) throw new Error(`the selection was not cleared after deleting: ${txt}`);
}

async function testDoneLeavesSelectingBehind(window) {
  await window.click('[data-act="pf-select-off"]');
  const bar = await window.evaluate(() => !!document.querySelector('.pf-bulk'));
  if (bar) throw new Error('the bar stayed after Done');
  const box = await window.evaluate(() => !!document.querySelector('.pf-pick'));
  if (box) throw new Error('the checkboxes stayed after Done');
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'printfiles-tab');
  await seed(window);

  await testSelectionSurvivesTheFilterMoving(window);
  await testBulkFilingUnifiesTheSpelling(window);
  await testAnEmptyBoxClears(window);
  await testTaggingAddsWithoutDiscarding(window);
  await testBulkDeleteTakesExactlyTheHeldRecords(window);
  await testDoneLeavesSelectingBehind(window);

  console.log('e2e-bulk-actions: ok (selection survives filtering, spelling unified, empty clears, tags add without discarding, delete takes exactly the held set)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}

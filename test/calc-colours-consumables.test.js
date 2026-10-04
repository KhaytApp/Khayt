'use strict';

/**
 * The desktop calculator's colours, purge and consumables (a tester's report;
 * the shapes are the Mac's, #1743): one helper applies them to the live price,
 * the total and the saved part, and a print file's consumables reach the part.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const P = require('../lib/part-from-print-file.js');

test('the live price, the total and the saved part all go through applyPartExtras', () => {
  const b = read('renderer/build.js');
  assert.match(b, /return computePartBaseCost\(applyPartExtras\(\{/, 'calculateLivePartCost');
  assert.match(b, /applyPartExtras\(snap\);\n\s+const bd = computePartBreakdown\(snap\);/, 'updateGrandTotal');
  assert.match(b, /function snapshotPartFromForm\(\) \{\n\s+return applyPartExtras\(snapshotPartFromFormRaw\(\)\);/, 'the saved part');
  for (const k of ['mainWeight:', 'colourLines:', 'purgeGrams:']) assert.ok(b.includes(k), `the part keeps ${k} so editing restores it`);
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) {
    const h = read(page);
    for (const id of ['colourLinesList', 'btnAddColourLine', 'purgeGrams', 'consumableLinesList', 'btnAddConsumableLine']) assert.match(h, new RegExp(`id="${id}"`), `${page} ${id}`);
  }
});

test('a print file\'s consumables per print reach the part, without overwriting the part\'s own', () => {
  const rec = { parsed: { filamentGrams: 20, printTimeMins: 60 }, consumables: [{ consumableId: 'C1', qty: 2, unitCost: 0.5, name: 'Magnet' }] };
  const patch = P.partPatch(rec);
  assert.deepEqual(patch.fields.consumables, rec.consumables);
  const empty = { consumables: [] };
  assert.deepEqual(P.autoFill(empty, patch).applied.includes('consumables'), true, 'an empty list is not filled in yet');
  const own = { consumables: [{ consumableId: 'C2', qty: 1 }] };
  P.autoFill(own, patch);
  assert.equal(own.consumables[0].consumableId, 'C2', 'the part\'s own consumables are kept');
  assert.equal(P.partPatch({ parsed: {} }).fields.consumables, undefined);
});

test('the print-file editor keeps consumables, and the calculator takes them from a linked file', () => {
  const pf = read('renderer/printfiles.js');
  assert.match(pf, /id="pfConsumables"/);
  assert.match(pf, /if \(cons\.length\) rec\.consumables = cons; else delete rec\.consumables;/);
  assert.match(read('renderer/wire-events.js'), /rec\.consumables\.length && !currentConsumableLines\.length/);
});

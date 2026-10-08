'use strict';

/**
 * Fixes from the alpha.60 pre-release review that live in the desktop's
 * renderer, where there is no DOM to drive in a unit test. Each reads the
 * source for the shape that was wrong.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

function body(src, marker) {
  const i = src.indexOf(marker);
  assert.ok(i >= 0, `${marker} not found`);
  const open = src.indexOf('{', src.indexOf('=>', i));
  let depth = 0;
  for (let k = open; k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}' && --depth === 0) return src.slice(open, k + 1);
  }
  throw new Error('unbalanced');
}

function mergeHelper() {
  const src = read('renderer/app-boot.js');
  const i = src.indexOf('async function mergeOrderFromDisk(');
  assert.ok(i >= 0, 'mergeOrderFromDisk not found');
  return 'async function mergeOrderFromDisk(id) ' + body(src.slice(i).replace('async function mergeOrderFromDisk(id) ', 'x = (id) => '), 'x = (id) =>');
}

test('a printer move or a survey is read back from disk, never written over from a stale copy', () => {
  const src = read('renderer/app-boot.js');
  for (const marker of ['onLanKanbanAdvanced?.(', 'onLanSurveySubmitted(']) {
    const handler = body(src, marker);
    assert.match(handler, /mergeOrderFromDisk\(/, marker);
    assert.doesNotMatch(handler, /applyStoreFromSnapshot\(/, `${marker} reloads the whole book`);
    assert.doesNotMatch(handler, /saveAll\(/, 'the window wrote its copy over the main process\'s write');
    assert.doesNotMatch(handler, /statusHistory/, 'a second history entry for one move');
  }
});

// v3.11.7 review: reloading the WHOLE book (applyStoreFromSnapshot) swapped every
// record for a new object, so an editor open on another job saved into an orphan —
// the toast said "Saved" and the edit was gone. v3.11.8 review (Mac lane): a save
// still in saveAll's debounce must be written BEFORE the read-back. Run the real code.
test('one job is merged in place, after any pending save is written', async () => {
  const a = { id: 'A', status: 'pending', notes: 'old' };
  const b = { id: 'B', status: 'pending', printingStartedAt: null, stale: 1 };
  const printLog = [a, b];
  const disk = { printLog: [{ id: 'A', status: 'pending', notes: 'old' }, { id: 'B', status: 'printing', printingStartedAt: '2026-10-08T08:00:00Z' }] };
  const order = [];
  const vm = require('node:vm');
  const ctx = { printLog, console,
    flushSave: async () => { order.push('flush'); },
    window: { hubAPI: { loadStore: async () => { order.push('load'); return disk; } } } };
  vm.createContext(ctx);
  vm.runInContext(mergeHelper(), ctx);
  await ctx.mergeOrderFromDisk('B');
  assert.deepEqual(order, ['flush', 'load'], 'a pending save is written before the book is read back');
  assert.equal(ctx.printLog[0], a, 'job A is the same object an open editor holds');
  assert.equal(ctx.printLog[1], b, 'job B is updated in place');
  assert.equal(b.status, 'printing');
  assert.equal(b.printingStartedAt, '2026-10-08T08:00:00Z', 'the start time the main process wrote');
  assert.ok(!('stale' in b), 'a field the move removed is removed');
});

test('a PIN that arrived only as the sync mask is refused, not cleared as legacy', () => {
  const src = read('renderer/ops-locations.js');
  const mask = src.indexOf("op.pinHash === '__KHAYT_MASKED__'");
  const legacy = src.indexOf('if (isLegacyPin(op.pinHash))');
  assert.ok(mask > 0 && legacy > 0);
  assert.ok(mask < legacy, 'the legacy branch would clear the mask first, leaving no PIN at all');
  for (const lang of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    assert.match(read(`renderer/locales/${lang}.js`), /"op\.pin_elsewhere":/, lang);
  }
});

test('an operator id is escaped wherever it is written into an option', () => {
  for (const f of ['renderer/ops-locations.js', 'renderer/order-flows.js']) {
    assert.doesNotMatch(read(f), /value="\$\{(op|o)\.id\}"/, f);
  }
});

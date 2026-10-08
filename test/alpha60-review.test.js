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

test('a printer move is read back from disk, never written over from a stale copy', () => {
  const handler = body(read('renderer/app-boot.js'), 'onLanKanbanAdvanced?.(');
  assert.match(handler, /loadStore\(\)/);
  assert.doesNotMatch(handler, /saveAll\(/, 'the window wrote its copy over the main process\'s write');
  assert.doesNotMatch(handler, /statusHistory/, 'a second history entry for one move');
});

// v3.11.7 review: reloading the WHOLE book (applyStoreFromSnapshot) swapped every
// record for a new object, so an editor open on another job saved into an orphan —
// the toast said "Saved" and the edit was gone. Run the real handler.
test('a printer move updates only its job, in place, so an open editor still saves', async () => {
  const handler = body(read('renderer/app-boot.js'), 'onLanKanbanAdvanced?.(');
  assert.doesNotMatch(handler, /applyStoreFromSnapshot\(/);
  const a = { id: 'A', status: 'pending', notes: 'old' };
  const b = { id: 'B', status: 'pending', printingStartedAt: null, stale: 1 };
  const printLog = [a, b];
  const disk = { printLog: [{ id: 'A', status: 'pending', notes: 'old' }, { id: 'B', status: 'printing', printingStartedAt: '2026-10-08T08:00:00Z' }] };
  const vm = require('node:vm');
  const ctx = { printLog, window: { hubAPI: { loadStore: async () => disk } }, console,
    renderKanban() {}, renderLogs() {}, toast() {}, applyStoreFromSnapshot() { throw new Error('whole-book reload'); } };
  vm.createContext(ctx);
  const fn = vm.runInContext(`(async ({ id, from, to, project }) => ${handler})`, ctx);
  await fn({ id: 'B', from: 'pending', to: 'printing', project: 'B' });
  assert.equal(ctx.printLog[0], a, 'job A is the same object an open editor holds');
  assert.equal(ctx.printLog[1], b, 'job B is updated in place');
  assert.equal(b.status, 'printing');
  assert.equal(b.printingStartedAt, '2026-10-08T08:00:00Z', 'the start time the main process wrote');
  assert.ok(!('stale' in b), 'a field the move removed is removed');
  a.notes = 'edited in the open editor';
  assert.equal(ctx.printLog.find((o) => o.id === 'A').notes, 'edited in the open editor');
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

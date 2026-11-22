'use strict';
/**
 * U1 idea 4: test/fixtures/per-head-actuals-vectors.json through
 * lib/printer-actuals.js perHeadActuals and perHeadPatch. The Mac runs the
 * same vectors when it wires the history read.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/printer-actuals.js');
const V = require('./fixtures/per-head-actuals-vectors.json');

for (const c of V.cases) test(c.why, () => assert.deepEqual(P.perHeadActuals(c.job), c.want));

const byId = (id) => P.perHeadActuals(V.cases.find((c) => c.job.job_id === id).job);
for (const c of V.patch) test('patch: ' + c.why, () => assert.deepEqual(P.perHeadPatch(c.order, byId(c.split)), c.want));

for (const c of V.colour) test('colour: ' + c.why, () => assert.deepEqual(P.headColour(c.head, c.at), c.want));
test('patch: ' + V.patchWithColour.why, () => {
  const c = V.patchWithColour;
  assert.deepEqual(P.perHeadPatch(c.order, byId(c.split), c.at), c.want);
  // Without what the printer held, the patch is what it always was: old callers and old jobs are unchanged.
  assert.deepEqual(P.perHeadPatch(c.order, byId(c.split)), V.patch[0].want);
});
test('colour: the real U1 reading (two tagged heads, two empty) through rfid-tray', () => {
  const U1 = require('./fixtures/u1-filament-detect.json');
  const fd = (U1.result && U1.result.status && U1.result.status.filament_detect) || U1.filament_detect || (U1.status && U1.status.filament_detect);
  const trays = require('../lib/rfid-tray.js').trays(fd);
  assert.equal(trays.length, 4);
  assert.equal(P.headColour(0, { trays }).colourFrom, 'rfid');
  assert.match(P.headColour(0, { trays }).hex, /^#[0-9A-F]{6}$/);
  assert.equal(P.headColour(2, { trays }), null, 'an empty head reports white and is not a colour');
  assert.equal(P.headColour(3, { trays }), null);
});

test('the heads add up to the total (to rounding), and no head is called measured on its own', () => {
  for (const c of V.cases.filter((x) => x.want)) {
    const r = P.perHeadActuals(c.job);
    const sum = r.heads.reduce((a, h) => a + h.grams, 0);
    assert.ok(Math.abs(sum - r.totalG) <= 0.1 * r.heads.length, c.why);
    assert.equal(r.basis, 'proportional');
  }
});

test('junk in, null out; the order is never changed', () => {
  for (const j of [null, 'x', 3, [], {}, { job_id: 'A', filament_used: 'x', metadata: { filament_weight: [1] } }, { job_id: 'A', filament_used: 10, metadata: { filament_weight: 'x' } }]) {
    assert.equal(P.perHeadActuals(j), null, JSON.stringify(j));
  }
  assert.equal(P.perHeadPatch({}, null), null);
  const order = { id: 'J1' };
  P.perHeadPatch(order, byId('000A2'));
  assert.deepEqual(order, { id: 'J1' });
});

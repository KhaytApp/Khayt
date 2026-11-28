'use strict';
/**
 * One spool, one head (lib/head-spools.js), against the shared vectors the Mac
 * and the phone are held to as well (test/fixtures/head-spools-vectors.json).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const H = require('../lib/head-spools');
const V = require('./fixtures/head-spools-vectors.json');

function machines(before) {
  return Object.entries(before).map(([id, h]) => (h === null ? { id, name: id } : { id, name: id, headSpools: h }));
}
function links(list) {
  const out = {};
  for (const m of list) out[m.id] = m.headSpools || {};
  return out;
}

for (const c of V.cases) {
  test('head-spools: ' + c.why, () => {
    const before = machines(c.before);
    const frozen = JSON.stringify(before);
    const r = c.call.op === 'link'
      ? H.link(before, c.call.machineId, c.call.head, c.call.spoolId)
      : H.unlink(before, c.call.machineId, c.call.head);
    const want = c.want;
    const after = links(r.machines);
    for (const [id, h] of Object.entries(want.after)) assert.deepEqual(after[id], h, id);
    assert.deepEqual(r.moved, want.moved);
    assert.deepEqual(r.changed, want.changed);
    assert.equal(r.error, want.error);
    assert.equal(JSON.stringify(before), frozen, 'the input machines are not changed in place');
    // Machines it did not change come back as the same objects.
    r.machines.forEach((m, i) => { if (!r.changed.includes(m.id)) assert.equal(m, before[i]); });
  });
}

for (const c of V.shown.cases) {
  test('head-spools shown: ' + c.why, () => assert.equal(H.shown(c.linked, c.reportsEmpty), c.want));
}

test('a spool can never end up in two heads, whatever order links come in', () => {
  let list = [{ id: 'A' }, { id: 'B' }];
  const steps = [['A', 0, 'S'], ['A', 1, 'S'], ['B', 0, 'S'], ['A', 0, 'T'], ['B', 2, 'T'], ['A', 3, 'S']];
  for (const [m, h, s] of steps) {
    list = H.link(list, m, h, s).machines;
    const all = list.flatMap((x) => Object.values(x.headSpools || {}));
    assert.equal(all.length, new Set(all).size, JSON.stringify(list));
  }
});

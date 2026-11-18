'use strict';
/**
 * test/fixtures/actual-times-vectors.json through lib/order-edit.js
 * applyJobEdit: correcting a job's actual times (Dev Hub, Nov 18). Only the
 * stamp moves (the job is otherwise byte-for-byte as it was: no finish rule
 * runs again), no stamp is created, and a future time or a completion before
 * the start is refused with nothing written. The Mac and the phone run it.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const E = require('../lib/order-edit.js');
const V = require('./fixtures/actual-times-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

for (const c of V.cases) {
  test(c.why, () => {
    const order = clone(c.order);
    const before = clone(order);
    const r = E.applyJobEdit(order, clone(c.next), { now: Date.parse(V.now), id: 'e', settings: {}, clients: [] });
    assert.equal(r.ok, c.want.ok, r.reason);
    if (!c.want.ok) {
      assert.equal(r.reason, c.want.reason);
      assert.equal(r.step, c.want.step);
      assert.deepEqual(order, before, 'a refusal writes nothing');
      assert.equal(E.actualTimes(clone(c.order), clone(c.next), { now: Date.parse(V.now) }), c.want.reason, 'actualTimes agrees');
      return;
    }
    const k = Object.keys(c.next)[0];
    assert.equal(order[k], c.want[k]);
    // Only the time moved: everything else is exactly as it was.
    const rest = clone(order); delete rest[k];
    const was = clone(before); delete was[k];
    assert.deepEqual(rest, was, 'no finish rule ran again: nothing else moved');
  });
}

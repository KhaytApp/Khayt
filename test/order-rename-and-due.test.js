'use strict';
/**
 * Two things the Mac could not do to a job (the Nov 10 2026 review): change
 * its name after it was taken, and take it WITH the day it was promised for.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
require('../lib/calculator-cost.js');
const E = require('../lib/order-edit.js');
const N = require('../lib/order-new.js');

test('a job can be renamed, the change is written down, and a blank name is "leave it"', () => {
  const o = { id: 'J1', project: 'Vaze', price: 10 };
  const r = E.applyEdit(o, { project: '  Vase  ' }, { now: Date.parse('2026-11-10T09:00:00Z'), id: 'e1' });
  assert.equal(o.project, 'Vase');
  assert.deepEqual(r.changes, { project: { from: 'Vaze', to: 'Vase' } });
  assert.deepEqual(o.editHistory[0].fields, { project: { from: 'Vaze', to: 'Vase' } });
  assert.deepEqual(E.applyEdit(o, { project: '   ' }, { now: 1, id: 'e2' }).changes, {});
  assert.deepEqual(E.applyEdit(o, { project: 'Vase' }, { now: 1, id: 'e3' }).changes, {});
  assert.equal(o.project, 'Vase');
  assert.equal(o.editHistory.length, 1, 'nothing changed, nothing recorded');
  assert.equal(E.editLog(o)[0].fields[0].field, 'project');
});

test('a rename rides with the other edits in one entry', () => {
  const o = { id: 'J2', project: 'A', price: 10, dueDate: null };
  const r = E.applyEdit(o, { project: 'B', dueDate: '2026-11-20' }, { now: 1, id: 'e1' });
  assert.deepEqual(Object.keys(r.changes).sort(), ['dueDate', 'project']);
  assert.equal(o.editHistory.length, 1);
});

test('a job taken with a promised day keeps it; without one the queue estimates; a quote has none', () => {
  const make = (extra) => N.newOrder(
    Object.assign({ parts: [{ name: 'a', material: 'PLA', baseCost: 100, printTime: 4, qty: 1 }], project: 'X', margin: 0 }, extra),
    { settings: { currency: 'SAR' }, orders: [], now: new Date('2026-11-10T09:00:00Z'), tokens: {} });
  const of = (out) => (out && out.order ? out.order : out);
  assert.equal(of(make({ dueDate: '2026-11-19' })).dueDate, '2026-11-19');
  const estimated = of(make({})).dueDate;
  assert.notEqual(estimated, '2026-11-19');
  assert.equal(of(make({ dueDate: 'Thursday' })).dueDate, estimated, 'not a day: the estimate, as before');
  assert.equal(of(make({ dueDate: '2026-11-19', asQuote: true })).dueDate, null);
});
